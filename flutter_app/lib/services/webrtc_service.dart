// BROKA - WebRTC Service
// Manages one P2P audio or video call via WebSocket signaling on the BROKA
// backend. Caller/callee exchange SDP + ICE through /calls/ws/{roomId}.
// Media goes peer-to-peer where possible; Cloudflare Realtime TURN relays
// it when direct connectivity isn't available (see _fetchIceConfiguration()
// below and GET /calls/turn-credentials on the backend).
//
// Hardening pass (production MVP): every async step below that resumes
// after an `await` checks _generation before touching _pc/_ws again, so a
// stale continuation from a call that's already been hung up/disposed
// can't crash on a null-checked reference or corrupt a state that's moved
// on. State transitions go through _setState()'s explicit table instead
// of being set unconditionally, so a duplicated/out-of-order signaling
// message (e.g. a stray "connected" callback after hangup) can't move the
// call backwards. ICE candidates that arrive before the remote
// description is set are queued, not dropped. A dropped WebSocket
// attempts bounded, backed-off reconnection instead of failing the call
// immediately - see _scheduleReconnect(). Once connected, a best-effort
// connection-path check (direct/STUN/TURN) runs once via getStats() -
// see ConnectionDiagnostics and _reportDiagnosticsOnceConnected().

import 'dart:async';
import 'dart:convert';
// Platform, for the Android-only audio-mode switch in _setAudioMode. Same
// `show Platform` narrow import ringtone_service.dart already uses for its
// own Android-only platform channel.
import 'dart:io' show Platform;
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'api_service.dart';

enum CallState {
  idle,
  connecting,
  calling,     // caller: sent offer, waiting for answer
  ringing,     // callee: received offer, waiting for user to accept
  connected,
  recovering,  // was connected, transient WebRTC disconnect - attempting ICE restart before giving up (Section 6)
  ended,
  failed,
}

/// Real, measured call quality - see WebRtcService._sampleQuality(). Derived
/// from inbound audio packet loss and jitter, never from elapsed time.
enum CallQuality { unknown, good, fair, bad }

// Lightweight, best-effort connection diagnostics (Sections 13-15) - built
// once, when the call actually connects, never streamed continuously.
// connectionPath answers the question Section 30 cares about most: was
// this call actually relayed through Cloudflare TURN, or did it connect
// directly/via STUN? Determined from RTCPeerConnection.getStats()'s
// selected candidate-pair - see _reportDiagnosticsOnceConnected(). Exposed
// via onDiagnostics for the UI (or a future backend-reporting call) to use;
// this file itself doesn't report anywhere yet - see that method's doc
// comment for the current scope boundary.
class ConnectionDiagnostics {
  final String connectionPath; // 'direct' | 'stun' | 'turn' | 'unknown'
  final Duration? timeToConnect;
  final int reconnectCount;
  final int iceRestartCount;
  const ConnectionDiagnostics({
    required this.connectionPath,
    this.timeToConnect,
    required this.reconnectCount,
    required this.iceRestartCount,
  });

  @override
  String toString() => 'ConnectionDiagnostics(path: $connectionPath, '
      'timeToConnect: $timeToConnect, reconnects: $reconnectCount, '
      'iceRestarts: $iceRestartCount)';
}

// Which transitions are legal from each state - mirrors the server-side
// state machine in api/core/call_state.py (kept intentionally simpler,
// since the client only ever tracks ITS OWN side of one call). Every
// terminal state (ended, failed) has an empty transition set, so nothing
// can move a call "backwards" out of it - the exact class of bug this
// guards against is a stale async callback (e.g. RTCPeerConnection
// reporting "connected" a moment after hangup() already ran) trying to
// resurrect a call that's already over.
const Map<CallState, Set<CallState>> _kAllowedTransitions = {
  // BUG FIX (calling audit, 2026-09-14): `idle` used to allow ONLY
  // `connecting`, which silently broke Decline and the missed-call timeout
  // outright. A callee's WebRtcService is constructed the moment the VoIP
  // screen opens but start() is not called until they tap Accept - so while
  // the phone is ringing the service sits at `idle`, not `ringing`. Tapping
  // Decline calls hangup() -> _setState(ended), which was rejected here as
  // an illegal idle->ended transition. Because the rejection is a silent
  // no-op, onStateChange never fired, so VoipCallScreen never logged the
  // result, never stopped, and never popped: the callee was left staring at
  // a frozen incoming-call screen with Accept/Decline still showing, and
  // the caller kept ringing until their own timer gave up. The 45s
  // no-answer timeout took the identical path and failed the same way, so
  // missed calls were never recorded either. Both terminal states are now
  // reachable from idle, which is simply the truth: a call can end before
  // it ever starts.
  CallState.idle:       {CallState.connecting, CallState.ended, CallState.failed},
  CallState.connecting: {CallState.calling, CallState.ringing, CallState.failed, CallState.ended},
  CallState.calling:    {CallState.connected, CallState.failed, CallState.ended},
  CallState.ringing:    {CallState.connected, CallState.failed, CallState.ended},
  CallState.connected:  {CallState.recovering, CallState.failed, CallState.ended},
  // A successful ICE restart brings this straight back to `connected`;
  // exhausting the retry budget (see _attemptIceRestart()) is what
  // actually reaches `failed` from here.
  CallState.recovering: {CallState.connected, CallState.failed, CallState.ended},
  CallState.failed:     {},
  CallState.ended:      {},
};

class WebRtcService {
  final String roomId;
  final bool   isCaller;
  final String userId;
  final String callToken; // short-lived, room-scoped - see GET /calls/turn-credentials's
                           // sibling auth endpoints and _connectWs() below
  final String callType; // 'audio' | 'video'

  WebRtcService({
    required this.roomId,
    required this.isCaller,
    required this.userId,
    required this.callToken,
    this.callType = 'audio',
  });

  bool get isVideo => callType == 'video';

  // ── Callbacks ─────────────────────────────────────────────────────────────
  ValueChanged<CallState>? onStateChange;
  ValueChanged<String>?    onError;
  /// Caller only: a phone of the callee's is ringing (the server's
  /// `callee_ringing`, sent once that phone acknowledged the call). Until
  /// then the caller has only reached the server - "Calling", not
  /// "Ringing".
  VoidCallback?            onPeerRinging;

  /// Caller only: the callee pressed Accept (the server's
  /// `callee_answered`). Their phone may need many seconds more to join -
  /// a closed app has to start first - so from here a slow start is the
  /// call connecting, not going unanswered.
  VoidCallback?            onPeerAnswered;

  /// See [onPeerAnswered].
  bool calleeAnswered = false;

  /// Why the other side ended the call, when the server said: "declined",
  /// or "no_answer" when nobody picked up. Set before the `ended` state
  /// change it explains.
  String? remoteEndReason;
  // Fires once the remote party's media is flowing - for a video call this
  // is also the cue that remoteRenderer now has a live feed attached.
  VoidCallback?            onRemoteStreamConnected;
  /// Fires ONLY when a remote **video** track actually arrives, and again
  /// (with `false`) if the remote video goes away.
  ///
  /// BUG FIX (video audit, 2026-09-14): the call screen used to flip to
  /// full-bleed remote video on `onRemoteStreamConnected`, which fires for
  /// ANY remote track and again from onConnectionState the moment the peer
  /// connection reports `connected`. On a video call the remote AUDIO track
  /// almost always lands first, so the UI swapped to an RTCVideoView that
  /// had no video frames in it - and because `_showRemoteVideo` also hides
  /// the avatar/ripple treatment, what the user actually saw was a black
  /// screen. If the far side's camera never came up at all (permission
  /// denied, camera busy), it stayed black for the whole call. That is
  /// almost certainly the "video call doesn't work" symptom: audio was
  /// fine, the picture was a void.
  ValueChanged<bool>?      onRemoteVideoChanged;
  // Fires once the local mic/camera stream is ready (localRenderer has a
  // feed attached, for video calls) - lets the UI show the self-preview the
  // instant it's available instead of waiting for the next state change.
  VoidCallback?            onLocalMediaReady;
  ValueChanged<Duration>?  onDurationTick;
  // Fires once, shortly after the call reaches `connected` - see
  // ConnectionDiagnostics doc comment above.
  ValueChanged<ConnectionDiagnostics>? onDiagnostics;

  // ── Video renderers (initialized only when callType == 'video') ──────────
  final RTCVideoRenderer localRenderer  = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();
  bool _renderersReady = false;
  bool get renderersReady => _renderersReady;

  // ── Private state ─────────────────────────────────────────────────────────
  RTCPeerConnection? _pc;
  MediaStream?       _local;
  WebSocketChannel?  _ws;
  Timer?             _durationTimer;
  Duration           _duration = Duration.zero;
  CallState          _state    = CallState.idle;
  bool               _muted    = false;
  bool               _speaker  = false;
  bool               _videoEnabled = true;
  bool               _offerSent = false;

  // Signaling recovery (Section 5): cached once we successfully
  // setLocalDescription, so a fresh 'ready' after a WS reconnect can
  // resend the SAME sdp instead of either assuming _offerSent means
  // "the callee actually received it" (it doesn't - only that we tried)
  // or silently doing nothing. Cleared implicitly by _remoteDescriptionSet
  // becoming true - once negotiation actually completes, there's nothing
  // left to resend.
  RTCSessionDescription? _lastLocalOffer;
  RTCSessionDescription? _lastLocalAnswer;

  // Bumped by _cleanup() - any async continuation captured before that
  // point (via `final gen = _generation;`) can tell it's now stale and
  // must not touch _pc/_ws or push a state change for a call that's
  // already torn down. See class doc comment above.
  int _generation = 0;

  // Duplicate-signaling guard (Section 8): once the remote description is
  // set, a second offer/answer for the same call must not be reprocessed.
  bool _remoteDescriptionSet = false;

  // True between sending an ICE-restart offer and receiving the answer to
  // it.
  //
  // BUG FIX (calling audit, 2026-09-14): _handleAnswer bailed out on
  // `_remoteDescriptionSet` with no exception for restarts, unlike
  // _handleOffer which has always had one. So the ICE-restart handshake
  // could never complete: the caller sent a restart offer, the callee
  // correctly accepted it and answered, and the caller then discarded that
  // answer as a "duplicate". The restart therefore always timed out, the
  // grace timer re-armed, the second attempt failed identically, and the
  // call died with "Connection could not recover" - meaning recovery from
  // an ordinary Wi-Fi/cell handoff never actually worked, on either side.
  bool _awaitingRestartAnswer = false;

  // Identifies the CURRENT WebSocket. Every listener callback captures the
  // epoch it was registered under and ignores anything from a superseded
  // socket.
  //
  // BUG FIX (calling audit, 2026-09-14): _connectWs() reassigned _ws
  // without invalidating the old channel's stream subscription. The old
  // socket's onDone/onError - the very events that triggered the reconnect
  // in the first place - therefore kept firing AFTER a healthy new socket
  // was in place, each one calling _onWsDisrupted() again and scheduling
  // another reconnect against a connection that was working fine. Result:
  // a single blip could cascade into repeated teardown/reconnect churn and
  // burn the whole retry budget on a live call.
  int _wsEpoch = 0;

  // Whether the OTHER side's signaling socket is currently down (the
  // backend's "peer_state disconnected" message). Distinct from our own
  // WebSocket being down, and from a WebRTC-level ICE disconnect.
  bool _peerSignalingDown = false;
  Timer? _peerRecoveryTimer;
  // How long to hold a call open while the peer is away before giving up.
  // Comfortably longer than the peer's own reconnect budget (~1+2+4+8s plus
  // connect time) so we never quit while they still have attempts left.
  static const _peerRecoveryTimeout = Duration(seconds: 30);

  // ICE candidates that arrive before setRemoteDescription() has actually
  // been called are queued here instead of being handed to
  // RTCPeerConnection.addCandidate(), which throws if called too early -
  // flushed by _flushPendingIce() the moment the remote description lands.
  final List<RTCIceCandidate> _pendingIce = [];
  static const _maxPendingIce = 120;

  CallState get state    => _state;
  bool get muted         => _muted;
  bool get speakerOn     => _speaker;
  bool get videoEnabled  => _videoEnabled;
  Duration get duration  => _duration;

  // ── ICE config: STUN (direct P2P discovery) + TURN (relay fallback) ──────
  // TURN is essential for real-world mobile networks - STUN-only ICE often
  // fails silently on carrier-grade NAT (very common on Kenyan mobile data),
  // which looks exactly like "call connects/rings but no audio flows".
  // TURN relay credentials now come from Cloudflare Realtime - short-lived,
  // fetched per-call via GET /calls/turn-credentials (see
  // _fetchIceConfiguration() below) - instead of a hardcoded third-party
  // credential. If that fetch fails for any reason, calls fall back to
  // this STUN-only config so direct P2P connectivity can still be
  // attempted rather than failing the call outright.
  static const _fallbackIceConfig = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
      {'urls': 'stun:stun2.l.google.com:19302'},
    ],
    'sdpSemantics': 'unified-plan',
  };

  // Set once ICE configuration is fetched for this call - checked in
  // _attemptIceRestart() (Phase 7) so a restart refreshes stale TURN
  // credentials via RTCPeerConnection.setConfiguration() first rather than
  // risking an expired credential on the restarted ICE path. Deliberately
  // NOT a continuous mid-call refresh loop: BROKA's calls are short 1-to-1
  // sessions well under Cloudflare's TTL, so anything beyond a pre-restart
  // check isn't justified yet.
  DateTime? _iceCredentialsExpireAt;

  // ── Connect timeout (Section 6) ───────────────────────────────────────────
  // Distinct from the 45s ring timer the VoIP screen already owns (that
  // one covers "nobody answered yet"): this covers "SDP/ICE exchange
  // itself has started but is stuck" - armed the moment we enter
  // calling/ringing, disarmed on any other transition (see _setState()).
  Timer? _connectTimeoutTimer;
  static const _connectTimeout = Duration(seconds: 30);

  // ── WebSocket reconnection (Section 7) ────────────────────────────────────
  int _reconnectAttempts = 0;
  static const _maxReconnectAttempts = 4;
  Timer? _reconnectTimer;

  // ── WebSocket watchdog (Phase 5) ──────────────────────────────────────────
  // The server pings every WS_HEARTBEAT_INTERVAL_SECONDS (15s); if NOTHING
  // arrives - not even a ping - for a full window beyond that, the
  // connection is silently dead (e.g. a mobile radio drop with no clean
  // FIN/RST) and waiting on WebSocketChannel's own onError/onDone would
  // otherwise mean waiting on the OS/transport's own, often much slower,
  // dead-peer detection. Reset on every inbound message, not just pings.
  Timer? _wsWatchdogTimer;
  static const _wsWatchdogTimeout = Duration(seconds: 25);

  void _armWsWatchdog() {
    _wsWatchdogTimer?.cancel();
    _wsWatchdogTimer = Timer(_wsWatchdogTimeout, () {
      if (_state == CallState.ended || _state == CallState.failed) return;
      _onWsDisrupted('No signaling activity for ${_wsWatchdogTimeout.inSeconds}s');
    });
  }

  // ── ICE restart (Section 6) ───────────────────────────────────────────────
  // A transient RTCPeerConnectionStateDisconnected doesn't mean the call
  // failed - ICE can and often does self-heal (a brief Wi-Fi/cell handoff,
  // a momentary NAT rebind) without any action here. Only if it's STILL
  // unhealthy after a short grace period do we attempt an ICE restart, and
  // only up to a bounded number of times before giving up for real.
  int _iceRestartAttempts = 0;
  static const _maxIceRestartAttempts = 2;
  static const _disconnectGracePeriod = Duration(seconds: 6);
  Timer? _disconnectGraceTimer;
  bool _iceRestartInProgress = false;

  // For ConnectionDiagnostics.timeToConnect - set once, when start() begins.
  DateTime? _connectingStartedAt;

  // ── Public API ────────────────────────────────────────────────────────────

  /// Start: get mic/camera → open WebSocket → create peer connection.
  /// Caller then sends an offer; callee waits for one.
  Future<void> start() async {
    final gen = _generation;
    _connectingStartedAt = DateTime.now();
    debugPrint('WebRTC: ${isCaller ? "CALL_INITIATED" : "CALL_ACCEPTED"} room=$roomId role=${isCaller ? "caller" : "callee"} type=$callType');
    _setState(CallState.connecting);
    try {
      if (isVideo) {
        await localRenderer.initialize();
        await remoteRenderer.initialize();
        _renderersReady = true;
      }
      debugPrint('WebRTC: LOCAL_MEDIA_REQUESTED room=$roomId');
      await _initMedia();
      if (gen != _generation) return;
      debugPrint('WebRTC: LOCAL_MEDIA_READY room=$roomId');
      onLocalMediaReady?.call();
      await _createPc();
      if (gen != _generation) return;
      debugPrint('WebRTC: WEBSOCKET_CONNECTING room=$roomId');
      await _connectWs();
      if (gen != _generation) return;
      // NOTE: the caller must NOT send its SDP offer here - at this point the
      // room may still be empty (the callee hasn't joined). An offer sent now
      // is relayed to nobody and lost, leaving the call stuck on "Calling…".
      // Instead we wait for the backend's "ready" signal (fired once BOTH
      // peers are in the room) and send the offer from _onSignal(). We only
      // flip the UI to "calling" so the caller sees feedback immediately.
      if (isCaller) {
        _setState(CallState.calling);
      }
    } catch (e) {
      if (gen == _generation) _fail('Could not start call: $e');
    }
  }

  Future<void> hangup() async {
    // Deliver the hangup BEFORE tearing the socket down, and give the event
    // loop a beat to actually flush it. _cleanup() closes the sink, and a
    // close racing an add() on the same turn can discard the queued frame -
    // which the peer experiences as the call simply going quiet until its
    // own timeout fires, rather than ending cleanly.
    try {
      _ws?.sink.add(jsonEncode({'type': 'hangup', 'room_id': roomId}));
      await Future<void>.delayed(const Duration(milliseconds: 60));
    } catch (e) {
      debugPrint('WebRTC: could not send hangup: $e');
    }
    await _cleanup();
    _setState(CallState.ended);
  }

  void toggleMute() {
    _muted = !_muted;
    _local?.getAudioTracks().forEach((t) => t.enabled = !_muted);
  }

  /// Flips between loudspeaker and earpiece. Returns the route actually in
  /// effect afterwards, so the UI reflects reality rather than assuming the
  /// switch succeeded (it can fail when a headset or Bluetooth device owns
  /// the route).
  Future<bool> toggleSpeaker() async {
    final wanted = !_speaker;
    try {
      await Helper.setSpeakerphoneOn(wanted);
      _speaker = wanted;
    } catch (e) {
      debugPrint('WebRTC: speaker toggle failed: $e');
    }
    return _speaker;
  }

  /// Turns the local camera feed on/off mid-call (audio keeps flowing).
  /// No-op for audio calls.
  ///
  /// Announces the change to the peer. Without that they keep receiving a
  /// live-but-black stream and go on showing a frozen frame - see the
  /// 'video_state' case in _onSignal.
  void toggleVideo() {
    if (!isVideo) return;
    _videoEnabled = !_videoEnabled;
    _local?.getVideoTracks().forEach((t) => t.enabled = _videoEnabled);
    _sendVideoState();
  }

  void _sendVideoState() {
    try {
      _ws?.sink.add(jsonEncode({
        'type': 'video_state', 'room_id': roomId, 'enabled': _videoEnabled,
      }));
    } catch (e) {
      // Best-effort: the peer's picture is cosmetic, and a signalling
      // reconnect re-announces it below.
      debugPrint('WebRTC: could not send video_state: $e');
    }
  }

  /// Flips between front/back camera mid-call. No-op for audio calls.
  Future<void> switchCamera() async {
    if (!isVideo || _local == null) return;
    final tracks = _local!.getVideoTracks();
    if (tracks.isNotEmpty) {
      try { await Helper.switchCamera(tracks.first); } catch (_) {}
    }
  }

  Future<void> dispose() async {
    _durationTimer?.cancel();
    // Awaited, not fire-and-forget: _cleanup() detaches the renderers from
    // their streams and closes the peer connection, and disposing a
    // renderer while that's still in flight is a native-side crash.
    await _cleanup();
    if (_renderersReady) {
      _renderersReady = false;
      try { await localRenderer.dispose(); } catch (_) {}
      try { await remoteRenderer.dispose(); } catch (_) {}
    }
  }

  // ── WebSocket signaling ───────────────────────────────────────────────────

  Future<void> _connectWs() async {
    const raw  = ApiService.baseUrl;
    final base = raw.startsWith('https://')
        ? raw.replaceFirst('https://', 'wss://')
        : raw.replaceFirst('http://', 'ws://');
    // Short-lived, room-scoped call_token (from POST /calls/initiate or
    // GET /calls/pending/{listingId} / /calls/{roomId}/token) - not the
    // normal long-lived access token, which used to sit in this URL where
    // it could end up in proxy/server access logs.
    final uri = Uri.parse('$base/calls/ws/$roomId?token=$callToken');

    // Retire the previous socket explicitly before standing up a new one.
    // Bumping the epoch is what makes the old subscription's callbacks
    // inert (see _wsEpoch); closing it releases the native socket instead
    // of leaving it dangling until GC.
    final previous = _ws;
    final epoch = ++_wsEpoch;
    if (previous != null) {
      try { previous.sink.close(); } catch (_) {}
    }

    final ws = WebSocketChannel.connect(uri);
    _ws = ws;
    ws.stream.listen(
      (raw) => _onSignal(raw, epoch),
      onError: (e) { if (epoch == _wsEpoch) _onWsDisrupted('Signal error: $e'); },
      onDone:  ()  { if (epoch == _wsEpoch) _onWsClosed(ws.closeCode); },
    );

    // Announce presence. The server doesn't read this (it authenticates
    // from the room-scoped token in the URL), but it's a cheap liveness
    // probe: if the socket is already unusable, this throws here rather
    // than failing silently later.
    ws.sink.add(jsonEncode({
      'type':    'join',
      'room_id': roomId,
      'user_id': userId,
      'role':    isCaller ? 'caller' : 'callee',
    }));
    debugPrint('WebRTC: WEBSOCKET_OPENING room=$roomId epoch=$epoch');

    // NOTE: the retry budget is deliberately NOT reset here.
    //
    // BUG FIX (calling audit, 2026-09-14): it used to be, on the stated
    // reasoning that "we got far enough to send on it without throwing".
    // That reasoning doesn't hold: WebSocketChannel.connect() is lazy and
    // sink.add() buffers, so both succeed against a server that is
    // unreachable, down, or rejecting the token. Every failed reconnect
    // therefore zeroed the counter moments before onError/onDone bumped it
    // back to 1 - so _maxReconnectAttempts was never actually reached and
    // a genuinely dead network produced an unbounded reconnect loop
    // (burning battery and radio on a call that was never coming back)
    // instead of failing cleanly. The budget now resets only in _onSignal,
    // on the first frame the SERVER sends us - the one thing that actually
    // proves the socket works end to end.
    _armWsWatchdog();
  }

  /// Caller: the callee has answered and joined (our offer went out to
  /// them). From here a slow start is negotiation, not "no answer".
  bool get peerJoined => _offerSent;

  /// A signalling frame as if the server had sent it - for tests.
  @visibleForTesting
  void debugReceiveSignal(String raw) => _onSignal(raw);

  void _onSignal(dynamic raw, [int? epoch]) {
    if (epoch != null && epoch != _wsEpoch) return; // superseded socket
    _armWsWatchdog();
    if (_reconnectAttempts != 0) {
      // Proof the current socket is live end to end (see _connectWs).
      debugPrint('WebRTC: WEBSOCKET_CONFIRMED_LIVE room=$roomId');
      _reconnectAttempts = 0;
      _reconnectTimer?.cancel();
    }
    try {
      final m    = jsonDecode(raw as String) as Map<String, dynamic>;
      final type = m['type'] as String?;

      switch (type) {
        case 'ping':
          // Server-side heartbeat (Phase 5) - just confirms this socket is
          // still alive; nothing else to do on our end.
          _ws?.sink.add(jsonEncode({'type': 'pong', 'room_id': roomId}));
          break;
        case 'video_state':
          // The peer turned their camera on or off.
          //
          // There is no WebRTC-level event for this. Disabling a track
          // (track.enabled = false) keeps the transceiver up and keeps
          // sending - black frames, not nothing - so `onEnded` never fires
          // and the receiving side has no way to know. The visible result
          // was a peer who "turned their camera off" leaving the other
          // person staring at a frozen final frame for the rest of the
          // call, with no way to tell that from a hung video pipeline.
          //
          // Cosmetic only: it toggles which surface the UI shows and can
          // never affect call state, which is why the server is willing to
          // relay it verbatim.
          _remoteVideoEnabled = m['enabled'] as bool? ?? true;
          onRemoteVideoChanged?.call(
              _remoteVideoEnabled && remoteRenderer.videoWidth > 0);
          break;
        case 'ready':
          // Both peers in room - caller sends offer now. Also fires again
          // on a WS reconnect (server re-sends 'ready' once room membership
          // reaches 2 again), which is what makes resend-on-reconnect work:
          // this is the ONE signal both sides can use to notice "signaling
          // just came back" without a separate reconnect-specific message.
          debugPrint('WebRTC: SIGNALING_READY room=$roomId');
          // Re-announce our camera state. 'ready' fires again after a WS
          // reconnect, and a video_state sent while the socket was down is
          // simply gone - leaving the peer's picture stuck on whatever it
          // was before the drop.
          if (isVideo && !_videoEnabled) _sendVideoState();
          if (isCaller) {
            if (_lastLocalOffer != null && !_remoteDescriptionSet) {
              // We already created+sent an offer, but the callee never
              // answered - most likely it never reached them (the WS
              // dropped in between). Resend the SAME sdp rather than
              // creating a fresh one: idempotent, no renegotiation loop.
              _ws?.sink.add(jsonEncode({
                'type': 'offer', 'room_id': roomId, 'sdp': _lastLocalOffer!.sdp,
              }));
              debugPrint('WebRTC: OFFER_SENT room=$roomId (resend after reconnect)');
            } else if (!_offerSent) {
              _sendOffer();
            }
            // else: _remoteDescriptionSet is already true - negotiation
            // finished before this 'ready' arrived (e.g. a late-arriving
            // duplicate); nothing to resend.
          } else if (_lastLocalAnswer != null) {
            // Callee side: we already answered once - resend in case it
            // never reached the caller before signaling dropped.
            _ws?.sink.add(jsonEncode({
              'type': 'answer', 'room_id': roomId, 'sdp': _lastLocalAnswer!.sdp,
            }));
            debugPrint('WebRTC: ANSWER_SENT room=$roomId (resend after reconnect)');
          }
          break;
        case 'offer':
          _handleOffer(m['sdp'] as String, isRestart: m['restart'] == true);
          break;
        case 'answer':
          _handleAnswer(m['sdp'] as String, isRestart: m['restart'] == true);
          break;
        case 'ice':
          _addIce(m['candidate'] as Map<String, dynamic>);
          break;
        case 'peer_state':
          // The peer's SIGNALING socket came or went. This is not a hangup
          // and must never be treated as one - see the backend's
          // finally-block comment in api/routers/calls.py. Media may well
          // still be flowing peer-to-peer the whole time this is true;
          // WebRTC does not need the signaling channel once connected.
          if (m['state'] == 'disconnected') {
            _onPeerSignalingLost();
          } else if (m['state'] == 'reconnected') {
            _onPeerSignalingRestored();
          }
          break;
        case 'callee_ringing':
          // Server-authored, never relayed: the callee's phone has the
          // call. Only meaningful while we're still waiting for an answer.
          if (isCaller && !_remoteDescriptionSet &&
              _state != CallState.ended && _state != CallState.failed) {
            onPeerRinging?.call();
          }
          break;
        case 'callee_answered':
          // Server-authored, never relayed, like callee_ringing.
          if (isCaller && !calleeAnswered &&
              _state != CallState.ended && _state != CallState.failed) {
            calleeAnswered = true;
            onPeerAnswered?.call();
          }
          break;
        case 'hangup':
          // Now genuinely only sent when somebody deliberately ended the
          // call (the peer's own hangup, or the server relaying a decline
          // or deciding nobody answered).
          remoteEndReason = m['reason'] as String?;
          debugPrint('WebRTC: CALL_ENDED room=$roomId reason=${remoteEndReason ?? 'remote_hangup'}');
          _cleanup();
          _setState(CallState.ended);
          break;
        case 'busy':
          if (_reconnectAttempts > 0 && _reconnectAttempts < _maxReconnectAttempts) {
            // Mid-reconnect: the server may not have reaped our previous
            // socket yet. Failing the call outright here would throw away
            // a call that's about to be perfectly recoverable - back off
            // and try again instead.
            debugPrint('WebRTC: busy during reconnect - retrying');
            _scheduleReconnect();
            break;
          }
          _cleanup();
          _setState(CallState.failed);
          onError?.call('Other party is busy');
          break;
        case 'error':
          _fail(m['message'] as String? ?? 'Unknown signaling error');
          break;
      }
    } catch (e) {
      debugPrint('WebRTC signal parse error: $e');
    }
  }

  // ── Peer signaling recovery ───────────────────────────────────────────────

  /// The OTHER side's signaling socket dropped. Hold the call open while
  /// they reconnect rather than tearing it down. Media often keeps flowing
  /// throughout - an established WebRTC connection doesn't need signaling -
  /// so in the common case the user hears nothing at all and the call
  /// simply continues.
  void _onPeerSignalingLost() {
    if (_state == CallState.ended || _state == CallState.failed) return;
    if (_peerSignalingDown) return;
    _peerSignalingDown = true;
    debugPrint('WebRTC: PEER_SIGNALING_LOST room=$roomId - holding for '
        '${_peerRecoveryTimeout.inSeconds}s');
    // Only surface this in the UI if media is ALSO down. If we're still
    // `connected`, the call is genuinely fine and saying "Reconnecting…"
    // would be a lie that alarms the user for no reason.
    final gen = _generation;
    _peerRecoveryTimer?.cancel();
    _peerRecoveryTimer = Timer(_peerRecoveryTimeout, () {
      if (gen != _generation) return;
      if (!_peerSignalingDown) return;
      if (_state == CallState.ended || _state == CallState.failed) return;
      if (_state == CallState.connected) {
        // Signaling never came back, but media is still flowing. Nothing is
        // actually broken for the user, so let the call continue - the
        // WebRTC connection state is what will eventually notice if it
        // does break.
        debugPrint('WebRTC: peer signaling still down but media healthy - continuing');
        return;
      }
      _fail('The other person lost connection');
    });
  }

  void _onPeerSignalingRestored() {
    if (!_peerSignalingDown) return;
    _peerSignalingDown = false;
    _peerRecoveryTimer?.cancel();
    _peerRecoveryTimer = null;
    debugPrint('WebRTC: PEER_SIGNALING_RESTORED room=$roomId');
  }

  /// The server's close code for "this call is over" (api/routers/calls.py:
  /// "Call no longer exists" / "Call already ended").
  static const int callOverCloseCode = 4004;

  /// The signalling socket closed. Normally a drop to reconnect from - but
  /// not when the server closed it because the call is over and it never
  /// connected: the caller hung up in the seconds between this phone's
  /// Accept and its socket joining. Retrying a call that is gone took the
  /// whole reconnect budget (~15s of "Connecting") before failing, and the
  /// phone counted as on a call meanwhile. A call that did connect keeps
  /// the old rule: media can outlive its signalling, so it is not ended on
  /// the server's word about the session alone.
  void _onWsClosed(int? code) {
    final neverConnected = _state == CallState.idle ||
        _state == CallState.connecting || _state == CallState.calling ||
        _state == CallState.ringing;
    if (code == callOverCloseCode && neverConnected) {
      debugPrint('WebRTC: CALL_ENDED room=$roomId reason=call_over (closed by server)');
      remoteEndReason = 'call_over';
      _cleanup();
      _setState(CallState.ended);
      return;
    }
    _onWsDisrupted(null);
  }

  /// The signalling socket closing with [code], as if the server had - for
  /// tests.
  @visibleForTesting
  void debugSocketClosed(int? code) => _onWsClosed(code);

  /// Fired on both a clean WS close and a transport error - either way the
  /// signaling channel is down. If the call is already over there's
  /// nothing to reconnect for; otherwise try bounded, backed-off
  /// reconnection before giving up on the call.
  void _onWsDisrupted(String? errorMsg) {
    debugPrint('WebRTC: ${errorMsg != null ? "WEBSOCKET_ERROR" : "WEBSOCKET_DISCONNECTED"} room=$roomId ${errorMsg ?? ""}');
    if (_state == CallState.ended || _state == CallState.failed) return;
    if (_reconnectAttempts >= _maxReconnectAttempts) {
      if (_state == CallState.connected) {
        // Signaling is gone for good, but the peer connection is still up
        // and audio/video is still flowing. WebRTC does not need the
        // signaling channel to keep an established call running, so ending
        // a working call here would be a self-inflicted drop. Stop
        // retrying and let onConnectionState be the judge of whether the
        // call is actually in trouble.
        debugPrint('WebRTC: signaling exhausted but media is up - keeping the call');
        return;
      }
      _fail(errorMsg ?? 'Connection lost - could not reconnect');
      return;
    }
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    final gen = _generation;
    _reconnectAttempts++;
    // Exponential backoff with jitter: ~1s, 2s, 4s, 8s +/- 30%, clamped to
    // a sane range - bounded by _maxReconnectAttempts so a genuinely dead
    // network fails the call cleanly instead of retrying forever.
    final baseMs   = 1000 * (1 << (_reconnectAttempts - 1));
    final jitterMs = (baseMs * 0.3 * (Random().nextDouble() * 2 - 1)).round();
    final delay    = Duration(milliseconds: (baseMs + jitterMs).clamp(500, 30000));
    debugPrint('WebRTC: WS disrupted, reconnect attempt '
        '$_reconnectAttempts/$_maxReconnectAttempts in ${delay.inMilliseconds}ms');
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () async {
      if (gen != _generation) return;
      if (_state == CallState.ended || _state == CallState.failed) return;
      try {
        await _connectWs();
      } catch (_) {
        if (gen == _generation) _onWsDisrupted('Reconnect failed');
      }
    });
    // NOTE on "room full" during reconnect: the backend caps a room at two
    // WebSocket peers, but it keys them by USER id and explicitly replaces
    // a reconnecting participant's own stale socket (see the
    // GHOST_SOCKET_REPLACED branch in api/routers/calls.py), so our own
    // not-yet-reaped connection can't make us look like a third party. A
    // 'busy' therefore means a genuinely different second participant -
    // except in the reconnect window, where it's worth one more attempt
    // rather than an instant failure; _onSignal's 'busy' case handles that
    // distinction.
  }

  // ── ICE restart (Section 6) ───────────────────────────────────────────────

  void _armDisconnectGraceTimer() {
    final gen = _generation;
    _disconnectGraceTimer?.cancel();
    _disconnectGraceTimer = Timer(_disconnectGracePeriod, () {
      if (gen != _generation) return;
      // Only the caller drives restart attempts (see _attemptIceRestart()'s
      // doc comment) - the callee just waits in `recovering`, relying on
      // the caller's restart offer arriving normally through _handleOffer,
      // or on native WebRTC's own eventual RTCPeerConnectionStateFailed as
      // a backstop if it truly can't recover. Running an independent
      // grace/attempt loop on both sides would let the callee's own
      // counter exhaust and fail the call while the caller's restart was
      // still legitimately in progress.
      if (_state == CallState.recovering && isCaller) {
        _attemptIceRestart();
      }
    });
  }

  Future<void> _attemptIceRestart() async {
    if (_iceRestartInProgress) return; // never run two restarts concurrently
    if (_pc == null) return;
    if (_iceRestartAttempts >= _maxIceRestartAttempts) {
      _fail('Connection could not recover after $_maxIceRestartAttempts attempt(s)');
      return;
    }
    _iceRestartInProgress = true;
    _iceRestartAttempts++;
    final gen = _generation;
    debugPrint('WebRTC: ICE_RESTART_STARTED room=$roomId attempt=$_iceRestartAttempts/$_maxIceRestartAttempts');
    try {
      // Refresh TURN credentials first if they're at or near expiry (Phase
      // 7) - restarting ICE with an expired TURN username/credential would
      // just fail relay candidates silently, defeating the point of
      // restarting at all. Cloudflare's TTL is long relative to a normal
      // call, so this is rarely live in practice, but a long-running call
      // (or one that's already been through an earlier restart) could
      // otherwise hit it. This intentionally does NOT do continuous
      // mid-call refresh (not justified for BROKA's short 1-to-1 calls per
      // the design note above) - only a pre-restart check, per the
      // spec's own "if full mid-call refresh isn't justified, do a safe
      // pre-restart refresh" allowance.
      // DEVICE-VERIFICATION-REQUIRED: setConfiguration() on an already-live
      // RTCPeerConnection is standard WebRTC/flutter_webrtc API, but this
      // exact path hasn't been exercised on a real call in this sandbox
      // (no Flutter toolchain here) - hence the broad catch below, which
      // falls through to restarting with whatever configuration is
      // already active if this fails for any reason, matching today's
      // exact (never-refreshed) behavior rather than aborting recovery.
      const margin = Duration(minutes: 2);
      final stale = _iceCredentialsExpireAt == null ||
          DateTime.now().isAfter(_iceCredentialsExpireAt!.subtract(margin));
      if (stale && _pc != null) {
        try {
          final freshConfig = await _fetchIceConfiguration();
          // FIX (calling audit, 2026-09-18): only push a refreshed
          // configuration onto a LIVE connection when it actually contains
          // TURN servers.
          //
          // _fetchIceConfiguration does not throw when the credential fetch
          // fails - it logs and returns the STUN-only fallback. The catch
          // below therefore never fired for the most likely failure, and
          // the code went on to setConfiguration() that fallback, STRIPPING
          // TURN from a connection that in all likelihood was only up
          // because of TURN. That turned a recovery attempt into a
          // downgrade, on exactly the networks (carrier-grade NAT on
          // Kenyan mobile data) where the relay is the only path that
          // works at all. Keeping the existing configuration is what the
          // comment above always intended.
          if (_iceConfigIsFallback) {
            debugPrint('WebRTC: TURN refresh unavailable - keeping existing ICE config');
          } else if (gen == _generation && _pc != null) {
            await _pc!.setConfiguration(freshConfig);
            debugPrint('WebRTC: ICE_CONFIG_REFRESHED room=$roomId');
          }
        } catch (e) {
          debugPrint('WebRTC: ICE config refresh failed, restarting with existing config: $e');
        }
      }

      // Only the offering side initiates a restart - flutter_webrtc/native
      // WebRTC picks up a fresh ICE ufrag/pwd from the 'iceRestart' offer
      // constraint. The answering side doesn't initiate anything here; it
      // just receives the resulting offer through the normal 'offer'
      // signaling path (see _handleOffer()'s isRestart param below, which
      // is what lets a restart offer through even though a remote
      // description was already set once).
      if (isCaller && _pc != null) {
        final offer = await _pc!.createOffer(
            {'iceRestart': true, 'offerToReceiveAudio': true, 'offerToReceiveVideo': isVideo});
        if (gen != _generation || _pc == null) return;
        final tuned = _tuneSdp(offer);
        await _pc!.setLocalDescription(tuned);
        _lastLocalOffer = tuned;
        // Tells _handleAnswer that the next answer is a legitimate
        // renegotiation, not a replayed duplicate to be discarded.
        _awaitingRestartAnswer = true;
        if (gen != _generation || _ws == null) return;
        _ws!.sink.add(jsonEncode({
          'type': 'offer', 'room_id': roomId, 'sdp': tuned.sdp, 'restart': true,
        }));
        debugPrint('WebRTC: ICE_RESTART_OFFER_SENT room=$roomId');
      }
      // If we're still in `recovering` after another grace period (the
      // restart offer went out but negotiation hasn't completed, or -
      // callee side - no restart offer has arrived yet), arm another
      // grace window; onConnectionState's connected case resets
      // _iceRestartAttempts and cancels this the moment it actually works.
      _armDisconnectGraceTimer();
    } catch (e, st) {
      debugPrint('WebRTC: ICE restart failed: $e\n$st');
      if (gen == _generation) _fail('Could not restart the connection: $e');
    } finally {
      _iceRestartInProgress = false;
    }
  }

  // ── SDP exchange ──────────────────────────────────────────────────────────

  Future<void> _sendOffer() async {
    final gen = _generation;
    try {
      if (_pc == null) return;
      _offerSent = true;
      // The callee has joined: from here the connect timeout applies.
      if (_state == CallState.calling) _armConnectTimeout();
      debugPrint('WebRTC: OFFER_CREATED room=$roomId');
      final offer = await _pc!.createOffer(
          {'offerToReceiveAudio': true, 'offerToReceiveVideo': isVideo});
      if (gen != _generation || _pc == null) return;
      final tuned = _tuneSdp(offer);
      await _pc!.setLocalDescription(tuned);
      _lastLocalOffer = tuned; // cache for resend - see 'ready' handler in _onSignal
      debugPrint('WebRTC: OFFER_SET_LOCAL room=$roomId');
      if (gen != _generation || _ws == null) return;
      _ws!.sink.add(jsonEncode({
        'type': 'offer', 'room_id': roomId, 'sdp': tuned.sdp,
      }));
      debugPrint('WebRTC: OFFER_SENT room=$roomId');
    } catch (e, st) {
      // FORENSIC FIX: this used to be called fire-and-forget from
      // _onSignal's synchronous 'ready' case with no error handling of
      // its own - Dart's try/catch only guards the synchronous prefix of
      // an async function up to its first `await`, so any failure in
      // createOffer()/setLocalDescription() (both very possible on a real
      // device - codec negotiation, native platform-channel errors, etc.)
      // became a truly unhandled Future rejection, which is very likely
      // what was surfacing as "the app closes" on a real device. Now it's
      // caught, logged with the full stack trace, and fails the call
      // cleanly instead.
      if (gen == _generation) {
        debugPrint('WebRTC: _sendOffer failed: $e\n$st');
        _fail('Could not create call offer: $e');
      }
    }
  }

  Future<void> _handleOffer(String sdp, {bool isRestart = false}) async {
    final gen = _generation;
    // Duplicate-offer guard (Section 8): once the remote description is
    // already set, a second 'offer' (a duplicated/replayed signaling
    // message) must not re-run the answer flow from scratch. A genuine
    // ICE-restart offer (Section 6) is the one deliberate exception - it's
    // a legitimate renegotiation, not a duplicate, so it's allowed through.
    if (_remoteDescriptionSet && !isRestart) {
      debugPrint('WebRTC: ignoring duplicate offer');
      return;
    }
    try {
      if (!isRestart) {
        // A restart offer arrives mid-call - moving to `ringing` would be
        // wrong (we're not receiving a new incoming call, just
        // renegotiating an existing one). recovering -> connected is
        // reached the normal way, via onConnectionState once ICE
        // reconnects, not through a state change here.
        _setState(CallState.ringing);
      }
      debugPrint('WebRTC: ${isRestart ? "ICE_RESTART_OFFER_RECEIVED" : "OFFER_RECEIVED"} room=$roomId');
      if (_pc == null) return;
      await _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
      debugPrint('WebRTC: REMOTE_DESCRIPTION_SET room=$roomId (offer)');
      if (gen != _generation || _pc == null) return;
      _remoteDescriptionSet = true;
      await _flushPendingIce();
      if (gen != _generation || _pc == null) return;
      final answer = await _pc!.createAnswer(
          {'offerToReceiveAudio': true, 'offerToReceiveVideo': isVideo});
      debugPrint('WebRTC: ANSWER_CREATED room=$roomId');
      if (gen != _generation || _pc == null) return;
      final tunedAnswer = _tuneSdp(answer);
      await _pc!.setLocalDescription(tunedAnswer);
      _lastLocalAnswer = tunedAnswer; // cache for resend - see 'ready' handler in _onSignal
      debugPrint('WebRTC: ANSWER_SET_LOCAL room=$roomId');
      // Negotiation is complete on this side, so the sender now has real
      // encodings to cap. See _applyVideoBitrateCap.
      await _applyVideoBitrateCap();
      if (gen != _generation || _ws == null) return;
      if (gen != _generation || _ws == null) return;
      _ws!.sink.add(jsonEncode({
        'type': 'answer', 'room_id': roomId, 'sdp': tunedAnswer.sdp,
        // Echo the flag back so the offerer can tell this answer apart from
        // a replayed duplicate of the original one (see _handleAnswer).
        if (isRestart) 'restart': true,
      }));
      debugPrint('WebRTC: ANSWER_SENT room=$roomId');
    } catch (e, st) {
      // Same fix as _sendOffer() above - see that method's comment.
      if (gen == _generation) {
        debugPrint('WebRTC: _handleOffer failed: $e\n$st');
        _fail('Could not answer the call: $e');
      }
    }
  }

  Future<void> _handleAnswer(String sdp, {bool isRestart = false}) async {
    final gen = _generation;
    // Duplicate-answer guard (Section 8) - same reasoning as _handleOffer,
    // and now with the same ICE-restart exception _handleOffer has always
    // had. An answer is legitimate (not a duplicate) when it answers a
    // restart offer we are actually waiting on: either the peer echoed our
    // `restart` flag back, or we know we're mid-restart. Without this the
    // restart handshake could never complete - see _awaitingRestartAnswer.
    final restartAnswer = isRestart || _awaitingRestartAnswer;
    if (_remoteDescriptionSet && !restartAnswer) {
      debugPrint('WebRTC: ignoring duplicate answer');
      return;
    }
    try {
      debugPrint('WebRTC: ${restartAnswer ? "ICE_RESTART_ANSWER_RECEIVED" : "ANSWER_RECEIVED"} room=$roomId');
      if (_pc == null) return;
      await _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
      debugPrint('WebRTC: REMOTE_DESCRIPTION_SET room=$roomId (answer)');
      if (gen != _generation) return;
      _remoteDescriptionSet = true;
      _awaitingRestartAnswer = false;
      await _flushPendingIce();
      if (gen != _generation) return;
      // Caller side: the answer completes negotiation, so this is the first
      // moment the video sender has real encodings. See
      // _applyVideoBitrateCap.
      await _applyVideoBitrateCap();
    } catch (e, st) {
      // Same fix as _sendOffer() above - see that method's comment.
      if (gen == _generation) {
        debugPrint('WebRTC: _handleAnswer failed: $e\n$st');
        _fail('Could not complete the call connection: $e');
      }
    }
  }

  void _addIce(Map<String, dynamic> c) {
    RTCIceCandidate candidate;
    try {
      candidate = RTCIceCandidate(
        c['candidate']     as String,
        c['sdpMid']        as String?,
        c['sdpMLineIndex'] as int?,
      );
    } catch (e) {
      debugPrint('WebRTC: malformed ICE candidate payload: $e');
      return;
    }
    debugPrint('WebRTC: ICE_CANDIDATE_RECEIVED room=$roomId');
    if (!_remoteDescriptionSet || _pc == null) {
      // Candidates can legitimately arrive before the offer/answer that
      // establishes the remote description, depending on network timing -
      // queue instead of calling addCandidate() too early, which throws.
      // Flushed by _flushPendingIce() once the remote description lands.
      debugPrint('WebRTC: ICE_CANDIDATE_QUEUED room=$roomId');
      // Bounded: if a remote description never arrives (a peer that joined
      // and then vanished mid-negotiation), this queue would otherwise grow
      // for as long as the peer keeps trickling candidates. Dropping the
      // oldest is safe - ICE candidates are individually optional, and the
      // most recent ones are the ones most likely to still be reachable.
      if (_pendingIce.length >= _maxPendingIce) {
        _pendingIce.removeAt(0);
      }
      _pendingIce.add(candidate);
      return;
    }
    _addIceNow(candidate);
  }

  Future<void> _addIceNow(RTCIceCandidate candidate) async {
    try {
      // FORENSIC FIX: this used to call addCandidate() without awaiting
      // it, which meant the try/catch around it was decorative - it could
      // only ever catch a synchronous throw, never the async rejection
      // addCandidate() actually produces on a real device when a
      // candidate is malformed or arrives in the wrong peer-connection
      // state (a very real, common WebRTC failure, and ICE candidates
      // flow frequently - many per call - so this was a high-probability
      // unhandled-exception source, consistent with the crash being
      // reported as happening "eventually", not immediately).
      await _pc?.addCandidate(candidate);
    } catch (e) {
      // Recorded, not silently swallowed (Section 9) - deliberately logs
      // only the exception, never the candidate/SDP content itself.
      debugPrint('WebRTC: failed to add ICE candidate: $e');
    }
  }

  Future<void> _flushPendingIce() async {
    if (_pendingIce.isEmpty) return;
    final queued = List<RTCIceCandidate>.from(_pendingIce);
    _pendingIce.clear();
    for (final c in queued) {
      await _addIceNow(c);
    }
    debugPrint('WebRTC: ICE_CANDIDATES_FLUSHED room=$roomId count=${queued.length}');
  }

  // ── SDP tuning (bandwidth efficiency) ─────────────────────────────────────

  // Target ceiling for the Opus audio stream, in bits per second.
  //
  // WebRTC's own Opus default negotiates around 32-40kbps mono and will
  // happily climb higher. BROKA's calls are one-to-one voice on East
  // African mobile data, where the constraint is almost never the phone -
  // it's a congested 3G/HSPA cell or a metered bundle. 24kbps is
  // comfortably above the point where Opus voice quality is transparent for
  // speech (Opus is designed to be good at 16-24kbps for wideband voice),
  // and roughly 40% cheaper than letting it run free. For video calls the
  // audio ceiling matters less, so it's given a little more headroom.
  static const _audioBitrateBpsVoice = 24000;
  static const _audioBitrateBpsVideo = 32000;

  /// Rewrites the Opus `a=fmtp` line in an SDP to cap bitrate and enable
  /// DTX before the description is set locally and sent to the peer.
  ///
  /// The two parameters that matter here:
  ///   • `usedtx=1` - discontinuous transmission. Opus stops sending audio
  ///     packets during silence and sends tiny comfort-noise updates
  ///     instead. On a normal conversation, where each side is silent
  ///     roughly half the time, this is a large real-world saving in both
  ///     data and radio wake-ups (which is battery), for no perceptible
  ///     quality cost. It is off by default in WebRTC.
  ///   • `maxaveragebitrate` - the ceiling described above.
  ///   • `stereo=0`/`sprop-stereo=0` - voice is mono; negotiating stereo
  ///     just doubles the payload for nothing.
  ///
  /// Deliberately conservative about failure: if the SDP doesn't look the
  /// way we expect (no Opus payload type, no fmtp line to amend, a codec
  /// negotiation we don't recognise), this returns the ORIGINAL description
  /// untouched rather than risking a malformed SDP. A call that isn't
  /// bandwidth-tuned is a minor inefficiency; a call with a corrupt SDP
  /// doesn't connect at all.
  RTCSessionDescription _tuneSdp(RTCSessionDescription desc) {
    final sdp = desc.sdp;
    if (sdp == null || sdp.isEmpty) return desc;
    try {
      final lines = sdp.split(RegExp(r'\r\n|\n'));
      // Find the Opus payload type from its rtpmap line, e.g.
      //   a=rtpmap:111 opus/48000/2
      String? opusPt;
      for (final line in lines) {
        final m = RegExp(r'^a=rtpmap:(\d+)\s+opus/', caseSensitive: false)
            .firstMatch(line);
        if (m != null) {
          opusPt = m.group(1);
          break;
        }
      }
      if (opusPt == null) {
        debugPrint('WebRTC: no Opus payload type in SDP - skipping audio tuning');
        return desc;
      }

      final bitrate = isVideo ? _audioBitrateBpsVideo : _audioBitrateBpsVoice;
      final wanted = <String, String>{
        'maxaveragebitrate': '$bitrate',
        'usedtx': '1',
        'stereo': '0',
        'sprop-stereo': '0',
        // Opus in WebRTC already defaults to FEC on; stating it explicitly
        // means it survives a peer that would otherwise negotiate it away.
        // In-band FEC is what makes Opus tolerate the 1-3% packet loss
        // that's normal on a congested mobile uplink without audible gaps.
        'useinbandfec': '1',
      };

      final fmtpPrefix = 'a=fmtp:$opusPt ';
      var amended = false;
      for (var i = 0; i < lines.length; i++) {
        if (!lines[i].startsWith(fmtpPrefix)) continue;
        // Merge into the existing parameter list, overriding any key we
        // care about and preserving every key we don't (the browser/native
        // stack puts real negotiation state in here - minptime, and on some
        // platforms others - and dropping those would be a regression).
        final existing = lines[i].substring(fmtpPrefix.length);
        final params = <String, String>{};
        for (final kv in existing.split(';')) {
          final t = kv.trim();
          if (t.isEmpty) continue;
          final eq = t.indexOf('=');
          if (eq <= 0) continue;
          params[t.substring(0, eq)] = t.substring(eq + 1);
        }
        params.addAll(wanted);
        lines[i] = fmtpPrefix +
            params.entries.map((e) => '${e.key}=${e.value}').join(';');
        amended = true;
        break;
      }

      if (!amended) {
        // No fmtp line for Opus at all - insert one directly after its
        // rtpmap line, which is where it belongs and where every stack
        // expects to find it.
        final rtpmapIdx = lines.indexWhere((l) =>
            l.startsWith('a=rtpmap:$opusPt ') &&
            l.toLowerCase().contains('opus/'));
        if (rtpmapIdx < 0) return desc;
        lines.insert(
          rtpmapIdx + 1,
          fmtpPrefix + wanted.entries.map((e) => '${e.key}=${e.value}').join(';'),
        );
      }

      debugPrint('WebRTC: SDP_TUNED room=$roomId opus_pt=$opusPt '
          'bitrate=${isVideo ? _audioBitrateBpsVideo : _audioBitrateBpsVoice} dtx=on');
      return RTCSessionDescription(lines.join('\r\n'), desc.type);
    } catch (e) {
      // Any surprise in SDP shape: keep the original. See doc comment.
      debugPrint('WebRTC: SDP tuning skipped ($e)');
      return desc;
    }
  }

  // ── Peer connection ───────────────────────────────────────────────────────

  /// Fetches short-lived Cloudflare TURN credentials from the BROKA backend
  /// and builds the ICE configuration for createPeerConnection(). Falls
  /// back to STUN-only (_fallbackIceConfig) if the fetch fails for any
  /// reason - direct P2P connectivity can still work without TURN, just
  /// not for callers behind carrier-grade NAT.
  /// True when the last _fetchIceConfiguration() call could NOT get real
  /// TURN credentials and handed back the STUN-only fallback. Checked
  /// before setConfiguration() on a live connection - see
  /// _attemptIceRestart.
  bool _iceConfigIsFallback = false;

  Future<Map<String, dynamic>> _fetchIceConfiguration() async {
    final creds = await ApiService.getTurnCredentials();
    final iceServers = creds?['ice_servers'];
    if (creds == null || iceServers is! List || iceServers.isEmpty) {
      debugPrint('WebRTC: TURN credentials unavailable, using STUN-only ICE');
      _iceConfigIsFallback = true;
      return _fallbackIceConfig;
    }
    _iceConfigIsFallback = false;
    final expiresIn = creds['expires_in'];
    if (expiresIn is int) {
      _iceCredentialsExpireAt = DateTime.now().add(Duration(seconds: expiresIn));
    }
    return {
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
    };
  }

  Future<void> _createPc() async {
    final gen = _generation;
    final iceConfig = await _fetchIceConfiguration();
    if (gen != _generation) return;
    _pc = await createPeerConnection(iceConfig);
    debugPrint('WebRTC: PEER_CONNECTION_CREATED room=$roomId');
    if (gen != _generation) { try { await _pc?.close(); } catch (_) {} return; }

    // Add local audio (+ video, for video calls) tracks. addTrack is async
    // and returns the sender - previously its Future was dropped on the
    // floor inside a forEach, so (a) the tracks weren't guaranteed to be
    // attached before createOffer ran, which on a slow device produces an
    // offer with no media in it, and (b) there was no handle on the video
    // sender to apply a send-side bitrate cap to.
    for (final t in (_local?.getTracks() ?? const <MediaStreamTrack>[])) {
      await _pc!.addTrack(t, _local!);
      debugPrint('WebRTC: ${t.kind == "video" ? "LOCAL_VIDEO_TRACK_ADDED" : "LOCAL_AUDIO_TRACK_ADDED"} room=$roomId');
    }
    if (gen != _generation) return;
    // NOT capping the bitrate here. Encodings don't exist until the
    // transceiver is negotiated - see _applyVideoBitrateCap's doc comment.
    // It is applied from the two places where negotiation has just
    // completed instead (_handleOffer's answer, _handleAnswer).

    // Send ICE candidates to remote peer
    _pc!.onIceCandidate = (c) {
      // FORENSIC FIX: this callback fires directly from the native
      // flutter_webrtc plugin with no error handling at all - any failure
      // in jsonEncode()/the WS sink's add() (e.g. StateError if the sink
      // happens to be closed/reconnecting right at this moment) became an
      // unhandled exception escaping a native platform-channel callback,
      // a plausible contributor to the reported crash. Both operations
      // here are synchronous, so a plain try/catch is sufficient - no
      // await needed.
      if (gen != _generation) return;
      if (c.candidate == null) return;
      try {
        _ws?.sink.add(jsonEncode({
          'type': 'ice', 'room_id': roomId,
          'candidate': {
            'candidate':     c.candidate,
            'sdpMid':        c.sdpMid,
            'sdpMLineIndex': c.sdpMLineIndex,
          },
        }));
        debugPrint('WebRTC: ICE_CANDIDATE_SENT room=$roomId');
      } catch (e) {
        debugPrint('WebRTC: failed to send local ICE candidate: $e');
      }
    };

    // Connection state machine - the ONLY thing allowed to move CallState
    // to `connected` (Section 13/Phase 10: WS/ICE-gathering/etc. state
    // changes are diagnostic-only below, never call _setState()).
    _pc!.onConnectionState = (s) {
      if (gen != _generation) return; // stale callback from a torn-down call
      try {
        debugPrint('WebRTC: PEER_CONNECTION_STATE room=$roomId state=$s');
        switch (s) {
          case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
            _disconnectGraceTimer?.cancel();
            _disconnectGraceTimer = null;
            _iceRestartAttempts = 0; // reset - this is either the first connect or a successful recovery
            _setState(CallState.connected);
            debugPrint('WebRTC: CALL_CONNECTED room=$roomId');
            _startTimer();
            _startQualitySampling();
            onRemoteStreamConnected?.call();
            _reportDiagnosticsOnceConnected();
            _reportWebRtcState('connected');
            break;
          case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
            debugPrint('WebRTC: CALL_FAILED room=$roomId reason=peer_connection_failed');
            _reportWebRtcState('failed');
            _fail('WebRTC connection failed');
            break;
          case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
            if (_state == CallState.connected) {
              // Don't fail immediately - ICE frequently self-heals from a
              // brief disconnect (Wi-Fi/cell handoff, momentary NAT
              // rebind) with no action needed. Give it a short grace
              // period; only attempt an ICE restart - and only then
              // eventually fail - if it's still unhealthy once that
              // expires.
              _reportWebRtcState('disconnected');
              _setState(CallState.recovering);
              debugPrint('WebRTC: entering recovery grace period (${_disconnectGracePeriod.inSeconds}s)');
              _armDisconnectGraceTimer();
            }
            break;
          default: break;
        }
      } catch (e, st) {
        // A caller-supplied callback (onRemoteStreamConnected, set by
        // VoipCallScreen) could in principle throw - e.g. if it isn't
        // careful about calling setState() after the widget's disposed.
        // This callback fires directly from native code, so let nothing
        // escape it uncaught.
        debugPrint('WebRTC: onConnectionState handler failed: $e\n$st');
      }
    };

    // Diagnostic-only (Section 13/Phase 10) - never drives CallState on
    // their own. "ICE gathering complete" is not "connected", and neither
    // is a lone ICE-connection-state change - onConnectionState above
    // (the overall peer connection state) is the only thing allowed to
    // move CallState, exactly to avoid the failure mode Section 13/Phase
    // 10 call out explicitly.
    _pc!.onIceGatheringState = (s) {
      if (gen != _generation) return;
      debugPrint('WebRTC: ICE_GATHERING_STATE room=$roomId state=$s');
    };
    _pc!.onIceConnectionState = (s) {
      if (gen != _generation) return;
      debugPrint('WebRTC: ICE_CONNECTION_STATE room=$roomId state=$s');
    };
    _pc!.onSignalingState = (s) {
      if (gen != _generation) return;
      debugPrint('WebRTC: signaling state = $s');
    };

    // Remote track received. For video calls this stream carries both the
    // audio and video tracks together, so attaching it to the renderer here
    // is correct regardless of which specific track fired the event.
    _pc!.onTrack = (event) {
      if (gen != _generation) return;
      try {
        final isVideoTrack = event.track.kind == 'video';
        debugPrint('WebRTC: ${isVideoTrack ? "REMOTE_VIDEO_TRACK_RECEIVED" : "REMOTE_AUDIO_TRACK_RECEIVED"} room=$roomId');
        if (event.streams.isEmpty) return;
        // Any remote media at all means the call is up.
        onRemoteStreamConnected?.call();

        if (!isVideoTrack || !isVideo) return;
        remoteRenderer.srcObject = event.streams[0];

        // Don't announce remote video until the renderer has actual
        // dimensions - i.e. a frame has really been decoded. srcObject
        // being set only means a track was attached; frames can be
        // seconds behind it, or never arrive if the far camera failed.
        // Showing the video surface before then is what produced the
        // black screen described on onRemoteVideoChanged above.
        if (_remoteVideoEnabled && remoteRenderer.videoWidth > 0) {
          onRemoteVideoChanged?.call(true);
        }
        remoteRenderer.onResize = () {
          if (gen != _generation) return;
          // _remoteVideoEnabled, not just dimensions: a peer who muted
          // their camera before we ever decoded a frame would otherwise
          // have the surface switched on by the first resize event.
          onRemoteVideoChanged?.call(
              _remoteVideoEnabled && remoteRenderer.videoWidth > 0);
        };

        // A remote track that ends (the peer turned their camera off, or
        // the track was removed) must take the video surface back down
        // rather than freezing on the last decoded frame.
        event.track.onEnded = () {
          if (gen != _generation) return;
          debugPrint('WebRTC: REMOTE_VIDEO_TRACK_ENDED room=$roomId');
          onRemoteVideoChanged?.call(false);
        };
      } catch (e, st) {
        // Same reasoning as onConnectionState above - never let a native
        // callback propagate an uncaught exception.
        debugPrint('WebRTC: onTrack handler failed: $e\n$st');
      }
    };
  }

  // Peer's camera state, as last announced by them. Defaults to true: a
  // peer on an older build never sends video_state, and assuming their
  // camera is on preserves exactly the previous behaviour for them.
  bool _remoteVideoEnabled = true;

  // Video send ceiling. Uncapped, libwebrtc's bandwidth estimator happily
  // ramps a 640x480 stream past 1Mbps, which on a congested East African
  // mobile uplink doesn't just make video bad - it starves the audio stream
  // sharing the same connection, so the CALL degrades too. 320kbps at
  // 640x480/24fps is a solid, stable picture on 3G/HSPA and leaves real
  // headroom for Opus.
  static const _videoMaxBitrateBps = 320000;
  static const _videoMaxFramerate = 24;

  /// Applies the send-side video ceiling via RTCRtpSender parameters. This
  /// is the reliable way to bound an outgoing stream - the `b=AS:` SDP line
  /// is honoured inconsistently across platforms, and a getUserMedia
  /// constraint only bounds capture, not what the encoder decides to spend.
  ///
  /// FIX (calling audit, 2026-09-18): this used to run exactly once, from
  /// _createPc, immediately after addTrack - and in that position it could
  /// not work:
  ///
  ///   1. It read the addTrack-returned sender's `parameters`, which in
  ///      flutter_webrtc is a CACHED Dart field populated from addTrack's
  ///      response, not a live read of native state.
  ///   2. Before the transceiver is negotiated that cache's `encodings`
  ///      list is empty, so the old code fabricated one. libwebrtc rejects
  ///      a setParameters() that changes the NUMBER of encodings
  ///      (InvalidModificationError) - so on the common path this threw and
  ///      was swallowed by the catch below.
  ///   3. Even where it didn't, setLocalDescription re-derives the sender's
  ///      real parameters from the negotiated SDP afterwards, discarding it.
  ///
  /// So the cap that exists specifically to stop video starving the audio
  /// sharing the same uplink was, in practice, never applied - which is the
  /// failure its own comment describes. It now runs AFTER negotiation and
  /// reads the sender back through getSenders(), which does hit native and
  /// returns the real, post-negotiation encodings to modify in place.
  Future<void> _applyVideoBitrateCap() async {
    if (!isVideo) return;
    final pc = _pc;
    if (pc == null) return;
    final gen = _generation;
    try {
      // Fresh from native - see the doc comment. The sender object
      // addTrack returned carries a stale Dart-side `parameters` cache and
      // must not be used here; getSenders() round-trips to native.
      final senders = await pc.getSenders();
      if (gen != _generation) return;
      RTCRtpSender? videoSender;
      for (final s in senders) {
        if (s.track?.kind == 'video') { videoSender = s; break; }
      }
      if (videoSender == null) {
        debugPrint('WebRTC: no video sender yet - bitrate cap deferred');
        return;
      }

      final params = videoSender.parameters;
      final encodings = params.encodings;
      if (encodings == null || encodings.isEmpty) {
        // Still un-negotiated. Adding an encoding here is exactly the
        // invalid modification described above, so don't - the post-answer
        // call will catch it once the real encodings exist.
        debugPrint('WebRTC: video encodings not negotiated yet - cap deferred');
        return;
      }
      for (final e in encodings) {
        e.maxBitrate = _videoMaxBitrateBps;
        e.maxFramerate = _videoMaxFramerate;
      }
      await videoSender.setParameters(params);
      debugPrint('WebRTC: VIDEO_BITRATE_CAPPED room=$roomId '
          'max=${_videoMaxBitrateBps ~/ 1000}kbps fps=$_videoMaxFramerate');
    } catch (e) {
      // Never fail a call over a tuning step - an uncapped stream still
      // works, it just competes harder for the uplink.
      debugPrint('WebRTC: could not cap video bitrate: $e');
    }
  }

  /// Asks for mic (and camera, for a video call) up front with a clear
  /// result, instead of letting getUserMedia throw an opaque platform error.
  ///
  /// FIX (video audit, 2026-09-14): nothing requested permissions anywhere
  /// in the call path. On a device where the camera permission had been
  /// denied - or "denied once" on Android, which is sticky - getUserMedia
  /// threw, `start()`'s catch turned it into "Could not start call:
  /// PlatformException(...)", and the user had no idea it was a permission
  /// problem or how to fix it. Worse, for a VIDEO call the throw took the
  /// whole call down even though the audio half was perfectly grantable.
  Future<String?> _ensurePermissions() async {
    try {
      final needed = <Permission>[Permission.microphone];
      if (isVideo) needed.add(Permission.camera);
      final statuses = await needed.request();

      if (statuses[Permission.microphone]?.isGranted != true) {
        return 'BROKA needs microphone access to place calls. '
            'Enable it in Settings > Apps > BROKA > Permissions.';
      }
      if (isVideo && statuses[Permission.camera]?.isGranted != true) {
        // Deliberately NOT fatal: fall back to an audio-only call rather
        // than refusing to connect at all. The user gets a working call and
        // a clear reason why there's no picture.
        _cameraDenied = true;
        debugPrint('WebRTC: camera denied - continuing as audio-only');
      }
      return null;
    } catch (e) {
      // permission_handler is unavailable or misbehaving - don't block the
      // call; getUserMedia will surface anything that's genuinely wrong.
      debugPrint('WebRTC: permission pre-flight skipped: $e');
      return null;
    }
  }

  bool _cameraDenied = false;

  /// True when this was started as a video call but the local camera isn't
  /// available, so only audio is being sent. The UI uses this to explain
  /// the missing self-preview instead of showing an empty box.
  bool get cameraUnavailable => _cameraDenied;

  Future<void> _initMedia() async {
    // Put the platform into telephony/communication audio mode BEFORE
    // opening the mic.
    //
    // FIX (calling audit, 2026-09-14): nothing configured the audio session
    // at all, so calls ran in Android's default MEDIA mode. Three real
    // consequences, all of which users experience as "the call sounds
    // bad": the hardware volume keys adjusted MEDIA volume rather than
    // call volume (so turning a quiet call up did nothing obvious), audio
    // routed through the media stream instead of the voice-call stream, and
    // the platform's hardware acoustic-echo-canceller and noise suppressor
    // - which are only engaged in communication mode - stayed off, leaving
    // only WebRTC's software AEC to handle speakerphone echo.
    await _configureAudioSession();

    final permissionError = await _ensurePermissions();
    if (permissionError != null) throw Exception(permissionError);

    // If the camera was denied we still place the call - just without a
    // local video track. The peer sees no picture from us; everything else
    // works normally.
    final wantVideo = isVideo && !_cameraDenied;

    _local = await navigator.mediaDevices.getUserMedia({
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl':  true,
      },
      'video': wantVideo
          ? {
              'facingMode': 'user',
              'width':  {'ideal': 640},
              'height': {'ideal': 480},
              // Capping capture frame rate is the cheapest bandwidth/CPU
              // saving available for video: 24fps is indistinguishable from
              // 30 for a talking head, and a budget phone's encoder has 20%
              // less work to do. `ideal` only - a hard `max` can make some
              // Android camera stacks refuse to open the device at all.
              'frameRate': {'ideal': 24},
            }
          : false,
    });
    if (isVideo && wantVideo) {
      localRenderer.srcObject = _local;
    }
    // Video calls start on speaker (nobody holds a phone to their ear to
    // watch video); voice calls start on the earpiece, like every other
    // phone call. Previously neither was set, so the starting route was
    // whatever the platform happened to default to - which on several
    // Android builds is loudspeaker for a WebRTC audio call, i.e. the
    // caller's private negotiation played out loud to the room.
    _speaker = isVideo;
    try {
      await Helper.setSpeakerphoneOn(_speaker);
    } catch (e) {
      debugPrint('WebRTC: could not set initial audio route: $e');
    }
  }

  /// Puts the platform into (or back out of) telephony audio mode.
  ///
  /// Helper.setAndroidAudioConfiguration is the live, mid-call-safe way to
  /// switch Android's audio mode. Deliberately NOT going through
  /// WebRTC.initialize()'s androidAudioConfiguration option: that only
  /// applies once at engine startup, and its exact argument shape has moved
  /// between plugin versions - this call has been stable and does the same
  /// job at the moment it's actually needed.
  ///
  /// FIX (calling audit, 2026-09-18), two bugs in one line:
  ///
  ///   • It was not awaited. The method returns a Future (it is a platform
  ///     channel round trip), so _initMedia went straight on to
  ///     getUserMedia - and the mic could open while the platform was still
  ///     in MEDIA mode. Android engages its hardware acoustic echo
  ///     canceller and noise suppressor based on the mode in force when the
  ///     stream is opened, so losing that race gives you a call with
  ///     software AEC only: the exact speakerphone echo this call exists to
  ///     prevent. Dropping the Future also meant the try/catch around it
  ///     caught nothing (a Dart try only guards the synchronous prefix),
  ///     so a failure was an unhandled rejection rather than the logged,
  ///     survivable event the catch intends.
  ///
  ///   • Nothing ever put it back. _cleanup called setSpeakerphoneOn(false)
  ///     and its comment claims that hands the route back "so the next
  ///     media playback (a voice note, the ringtone) isn't stuck in
  ///     earpiece/communication mode" - but the speaker flag is not the
  ///     audio MODE. The device stayed in VOICE_COMMUNICATION for the rest
  ///     of the app session: the hardware volume keys kept adjusting call
  ///     volume instead of media volume, and voice notes and the next
  ///     incoming-call ringtone played on the voice-call stream.
  Future<void> _setAudioMode({required bool inCall}) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      await Helper.setAndroidAudioConfiguration(inCall
          ? AndroidAudioConfiguration.communication
          : AndroidAudioConfiguration.media);
      debugPrint('WebRTC: AUDIO_MODE_${inCall ? "COMMUNICATION" : "MEDIA"} room=$roomId');
    } catch (e) {
      // Not fatal - the call still works, it just falls back to the
      // platform default routing described above.
      debugPrint('WebRTC: audio session configuration unavailable: $e');
    }
  }

  Future<void> _configureAudioSession() => _setAudioMode(inCall: true);

  // ── Diagnostics (Sections 13-15) ──────────────────────────────────────────

  /// Best-effort connection-path detection via getStats() - answers "did
  /// this call actually use Cloudflare TURN, or connect directly/via
  /// STUN?" (Section 14/30). Called once, right after the peer connection
  /// reports `connected`; never polled/streamed continuously (Section 35).
  /// Parsing WebRTC stats reports varies subtly by platform/version, so
  /// this is wrapped defensively throughout - any parsing miss just
  /// leaves connectionPath as 'unknown' rather than throwing. NOT
  /// verified against a real call in this environment - the diagnostic
  /// itself (this method existing, being called at the right time, never
  /// crashing) is solid; the exact stats field names it looks for should
  /// be double-checked against a real getStats() dump on a live call.
  Future<void> _reportDiagnosticsOnceConnected() async {
    final gen = _generation;
    if (_pc == null) return;
    String path = 'unknown';
    try {
      final stats = await _pc!.getStats();
      Map<String, dynamic>? selectedPair;
      for (final report in stats) {
        final v = report.values;
        if (report.type == 'candidate-pair' &&
            v['state'] == 'succeeded' &&
            (v['nominated'] == true || v['selected'] == true)) {
          // report.values comes back as Map<dynamic, dynamic> from
          // flutter_webrtc - not assignable to Map<String, dynamic>?
          // without an explicit conversion, even though every key here is
          // always a String (a WebRTC stats field name).
          selectedPair = Map<String, dynamic>.from(v);
          break;
        }
      }
      final localId = selectedPair?['localCandidateId'];
      if (localId != null) {
        for (final report in stats) {
          if (report.id == localId && report.type == 'local-candidate') {
            final candidateType = report.values['candidateType'] as String?;
            if (candidateType == 'relay') {
              path = 'turn';
            } else if (candidateType == 'srflx' || candidateType == 'prflx') {
              path = 'stun';
            } else if (candidateType == 'host') {
              path = 'direct';
            }
            break;
          }
        }
      }
    } catch (e) {
      // Never crashes the call over a diagnostics-only failure - see
      // Section 9's "don't silently swallow, but don't let it break
      // anything either" spirit, applied here too.
      debugPrint('WebRTC: could not determine connection path: $e');
    }
    if (gen != _generation) return;
    debugPrint('WebRTC: connection path = $path');
    onDiagnostics?.call(ConnectionDiagnostics(
      connectionPath: path,
      timeToConnect: _connectingStartedAt != null
          ? DateTime.now().difference(_connectingStartedAt!)
          : null,
      reconnectCount: _reconnectAttempts,
      iceRestartCount: _iceRestartAttempts,
    ));
  }

  /// Tells the backend which WebRTC peer-connection state we just reached
  /// (Sections 5, 33) - the server can't observe this on its own, since it
  /// only relays opaque SDP/ICE messages. Best-effort: if the WS happens
  /// to be down right when this fires, the state simply isn't recorded
  /// server-side this time - never worth failing the call over.
  void _reportWebRtcState(String webrtcState) {
    try {
      _ws?.sink.add(jsonEncode({
        'type': 'state', 'state': webrtcState, 'room_id': roomId,
      }));
    } catch (_) {}
  }

  // ── Live call quality (replaces the elapsed-time guess) ───────────────────
  //
  // The VoIP screen used to derive its quality badge purely from how long
  // the call had been up: under 5s "Connecting", under 30s "Good", then
  // "Excellent" forever. That is not a measurement - a call relaying
  // through TURN with 40% packet loss reported "Excellent" at 31 seconds.
  // This samples the real inbound-audio stats instead, cheaply (once every
  // few seconds, one getStats call) and defensively - if the numbers aren't
  // there, quality stays `unknown` and the UI shows nothing rather than a
  // reassuring lie.
  Timer? _qualityTimer;
  static const _qualitySampleInterval = Duration(seconds: 4);
  int? _lastPacketsReceived;
  int? _lastPacketsLost;
  CallQuality _quality = CallQuality.unknown;
  CallQuality get quality => _quality;
  ValueChanged<CallQuality>? onQualityChange;

  void _startQualitySampling() {
    _qualityTimer?.cancel();
    final gen = _generation;
    _qualityTimer = Timer.periodic(_qualitySampleInterval, (_) async {
      if (gen != _generation) return;
      final q = await _sampleQuality();
      if (gen != _generation) return;
      if (q != _quality) {
        _quality = q;
        onQualityChange?.call(q);
      }
    });
  }

  Future<CallQuality> _sampleQuality() async {
    final pc = _pc;
    if (pc == null) return CallQuality.unknown;
    try {
      final stats = await pc.getStats();
      int? packetsReceived;
      int? packetsLost;
      double? jitterSeconds;
      for (final report in stats) {
        if (report.type != 'inbound-rtp') continue;
        final v = report.values;
        if (v['kind'] != 'audio' && v['mediaType'] != 'audio') continue;
        packetsReceived = (v['packetsReceived'] as num?)?.toInt();
        packetsLost = (v['packetsLost'] as num?)?.toInt();
        jitterSeconds = (v['jitter'] as num?)?.toDouble();
        break;
      }
      if (packetsReceived == null || packetsLost == null) {
        return CallQuality.unknown;
      }

      // Deltas since the previous sample, so a burst of loss early in the
      // call doesn't permanently colour the rest of it.
      //
      // FIX (calling audit, 2026-09-18): clamped at zero, and the counters
      // are reset in _cleanup. Both halves of the same bug: these fields
      // survived a call, so the FIRST sample of the SECOND call in an app
      // session subtracted the previous call's cumulative totals from this
      // one's - a large negative delta, which fell into the `total <= 0`
      // branch below and reported a perfectly healthy call as "bad" for its
      // first few seconds. The clamp additionally covers a counter reset
      // mid-call (an ICE restart re-creates the inbound stream) and the
      // fact that packetsLost is a SIGNED field in the WebRTC stats spec -
      // it can legitimately decrease when duplicates arrive.
      final dReceived = max(0, packetsReceived - (_lastPacketsReceived ?? 0));
      final dLost = max(0, packetsLost - (_lastPacketsLost ?? 0));
      _lastPacketsReceived = packetsReceived;
      _lastPacketsLost = packetsLost;

      final total = dReceived + dLost;
      if (total <= 0) {
        // No audio arrived at all in this window. On a connected call that
        // means the media path has stalled even though ICE still believes
        // it's up - worth surfacing, since it's exactly the "call connects
        // but I can't hear anything" case.
        return _state == CallState.connected
            ? CallQuality.bad
            : CallQuality.unknown;
      }
      final lossRatio = dLost / total;
      final jitterMs = (jitterSeconds ?? 0) * 1000;

      if (lossRatio > 0.10 || jitterMs > 100) return CallQuality.bad;
      if (lossRatio > 0.03 || jitterMs > 40) return CallQuality.fair;
      return CallQuality.good;
    } catch (e) {
      debugPrint('WebRTC: quality sample failed: $e');
      return CallQuality.unknown;
    }
  }

  // ── Duration timer ────────────────────────────────────────────────────────
  void _startTimer() {
    _durationTimer?.cancel();
    _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _duration += const Duration(seconds: 1);
      onDurationTick?.call(_duration);
    });
  }

  // ── Cleanup ───────────────────────────────────────────────────────────────

  Future<void> _cleanup() async {
    debugPrint('WebRTC: DISPOSE_STARTED room=$roomId');
    _generation++; // invalidate any in-flight async continuation - see class doc comment
    _wsEpoch++;    // and any callback from the socket we're about to close
    _durationTimer?.cancel();
    _connectTimeoutTimer?.cancel();
    _reconnectTimer?.cancel();
    _disconnectGraceTimer?.cancel();
    _wsWatchdogTimer?.cancel();
    _peerRecoveryTimer?.cancel();
    _qualityTimer?.cancel();
    // Detach the renderers from the streams BEFORE those streams are
    // stopped and disposed. flutter_webrtc's native side can crash if a
    // renderer is still holding a track that's been torn down underneath
    // it; nulling srcObject first is the documented-safe order.
    try {
      if (_renderersReady) {
        localRenderer.srcObject = null;
        remoteRenderer.srcObject = null;
      }
    } catch (_) {}
    try { await _pc?.close();  } catch (_) {}
    try {
      _local?.getTracks().forEach((t) => t.stop());
      await _local?.dispose();
    } catch (_) {}
    try { await _ws?.sink.close(); } catch (_) {}
    // Hand the audio route AND the audio mode back to the platform, so the
    // next media playback (a voice note, the next call's ringtone) isn't
    // stuck on the voice-call stream for the rest of the session. The
    // speaker flag alone never did this - see _setAudioMode.
    try { await Helper.setSpeakerphoneOn(false); } catch (_) {}
    await _setAudioMode(inCall: false);
    _pc = null; _local = null; _ws = null;
    _iceCredentialsExpireAt = null;
    _pendingIce.clear();
    _peerSignalingDown = false;
    _awaitingRestartAnswer = false;
    // Per-call quality state. Left over, these make the NEXT call's first
    // sample a negative delta against this call's totals - see
    // _sampleQuality.
    _lastPacketsReceived = null;
    _lastPacketsLost = null;
    _quality = CallQuality.unknown;
    _cameraDenied = false;
    debugPrint('WebRTC: DISPOSE_COMPLETED room=$roomId');
  }

  void _setState(CallState s) {
    if (_state == s) return; // idempotent no-op - a duplicated signal re-asserting the same state isn't an error
    final allowed = _kAllowedTransitions[_state] ?? const {};
    if (!allowed.contains(s)) {
      // e.g. a stale "connected" callback arriving after the call already
      // moved to ended/failed - see the class doc comment on _generation
      // for why this can happen, and why it must be a no-op, not a crash.
      debugPrint('WebRTC: ignored invalid state transition ${_state.name} -> ${s.name}');
      return;
    }
    _state = s;
    // The caller is `calling` from the moment its socket is up - while the
    // callee's phone is still ringing and nobody has answered. Arming the
    // 30s connect timeout then cut every call off after 30 seconds of
    // ringing as "Call timed out while connecting", fifteen seconds before
    // the callee's phone stopped ringing. For the caller it starts when the
    // offer goes out (_sendOffer): the callee has answered and joined, and
    // from there 30s really is a stuck negotiation. The no-answer window is
    // the call screen's (and the server's).
    if (s == CallState.ringing || (s == CallState.calling && _offerSent)) {
      _armConnectTimeout();
    } else {
      _disarmConnectTimeout();
    }
    onStateChange?.call(s);
  }

  void _armConnectTimeout() {
    _connectTimeoutTimer?.cancel();
    _connectTimeoutTimer = Timer(_connectTimeout, () {
      // Distinct failure reason from the VoIP screen's own 45s "nobody
      // answered" ring timeout - this fires only once SDP exchange has
      // actually started (calling/ringing) and then stalled.
      if (_state == CallState.calling || _state == CallState.ringing) {
        _fail('Call timed out while connecting');
      }
    });
  }

  void _disarmConnectTimeout() {
    _connectTimeoutTimer?.cancel();
    _connectTimeoutTimer = null;
  }

  void _fail(String msg) {
    debugPrint('WebRTC: CALL_FAILED room=$roomId reason=$msg');
    _cleanup();
    _setState(CallState.failed);
    onError?.call(msg);
  }
}
