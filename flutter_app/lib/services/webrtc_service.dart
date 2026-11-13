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
//
// Answering without "Connecting…" (2026-11-09, CALLING.md): a voice call
// ringing on the in-app screen of an Android phone is negotiated while it
// rings - see prepareRinging() and the block of fields it opens.

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
import 'call_diagnostics.dart';
import '../core/errors/user_facing_error.dart';

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
  // connecting -> connected: a callee whose call was negotiated while it
  // rang is connected as its microphone opens, with no offer to wait for.
  CallState.connecting: {CallState.calling, CallState.ringing, CallState.connected,
                         CallState.failed, CallState.ended},
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

  /// Short-lived, room-scoped - see GET /calls/turn-credentials's sibling
  /// auth endpoints and _connectWs() below. Renewed when a reconnect is
  /// refused for it (4001): it lasts five minutes, and a socket that
  /// dropped later in a call could otherwise never come back.
  String get callToken => _callToken;
  String _callToken;

  WebRtcService({
    required this.roomId,
    required this.isCaller,
    required this.userId,
    required String callToken,
    String callType = 'audio',
  })  : _callToken = callToken,
        _callType = callType,
        diagnostics = CallDiagnostics(roomId: roomId, role: isCaller ? 'caller' : 'callee') {
    diagnostics.sendOverSocket = _sendDiag;
  }

  /// This call's events for Render's logs (call_diagnostics.dart).
  final CallDiagnostics diagnostics;

  /// Why this call failed, when it did: no_offer, ice_failed, ice_timeout,
  /// signaling_lost, peer_lost, media_failed... - for the screen's message
  /// and the recorded outcome.
  String? get failureReason => _failureReason;
  String? _failureReason;

  /// The WebRTC connection came up at least once.
  bool get everConnected => _everConnected;
  bool _everConnected = false;

  /// Caller only: the server could not push the callee's phone after all
  /// (`push_status`, sent when the push finished after /initiate answered).
  ValueChanged<String>? onPushStatus;

  /// 'audio' | 'video'. A voice call becomes a video call when either side
  /// turns a camera on (upgradeToVideo, or the other side's picture
  /// arriving) - see [onCallTypeChanged].
  String get callType => _callType;
  String _callType;

  bool get isVideo => _callType == 'video';

  /// The call became a video call: this side turned its camera on, or the
  /// other side's picture arrived on a voice call.
  ValueChanged<String>?    onCallTypeChanged;

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

  /// Caller only: the callee's phone joined the call (the server's
  /// `ready`), and the offer is on its way to it.
  VoidCallback?            onPeerJoined;

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

  // Signaling recovery (Section 5): cached once we successfully
  // setLocalDescription, so a fresh 'ready' after a WS reconnect can
  // resend the SAME sdp instead of assuming that an offer sent means
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

  // ── Candidates and the descriptions they belong to (2026-11-13) ─────────
  // A candidate is only good for the ICE session (offer or answer) it was
  // gathered for, and it was possible for it to arrive before that one:
  //
  //  * here, candidates went out as soon as they were gathered - between
  //    setLocalDescription and the description itself being sent. For an
  //    ICE restart, a re-offer after a ringing phone changed, or an answer,
  //    the other phone could then receive them first and add them to the
  //    description it still had, where they were refused and lost. The
  //    relay candidate - the one carrier-grade NAT needs - is gathered last
  //    and often was the one lost, so a restart meant to rescue a call
  //    could not.
  //  * there, a candidate arriving while setRemoteDescription was still
  //    running was added at once against the old description.
  //
  // Now a description's candidates are held until it has been sent
  // (_holdLocalIce), and a received candidate waits while a description is
  // being applied (_applyingRemote) or when it names an ICE session other
  // than the one applied (_remoteUfrag) - it is for a description still on
  // its way.
  bool _holdLocalIce = false;
  bool _applyingRemote = false;
  String? _remoteUfrag;
  // This phone's candidates for its current description, sent once: again
  // after a signalling reconnect, since any trickled while a socket was
  // down are gone.
  final List<String> _sentLocalIce = [];

  // ── What the phone sees, for the logs (call_diagnostics.dart) ───────────
  String _wsState = 'none';
  String _iceGatheringName = 'new';
  String _iceConnectionName = 'new';
  String _pcStateName = 'new';
  String _path = '-';
  bool _everOpenedSocket = false;
  int? _socketReportedEpoch;
  bool _turnConfigured = false;
  StreamSubscription<dynamic>? _wsSub;
  bool _tokenRefreshTried = false;

  // ── A connection that never came up (2026-11-13) ────────────────────────
  // An ICE failure before the call ever connected ended it at once, with no
  // second try - often the relay's credentials had not come in time, or
  // the first path chosen died. The caller now restarts ICE once, with
  // fresh TURN credentials, before giving up; the callee waits for that.
  int _initialRestarts = 0;
  static const _maxInitialRestarts = 1;
  static const _restartWindow = Duration(seconds: 20);
  // The callee gives the caller - who drives restarts - longer than the
  // caller's own budget before it gives up on a connection itself.
  static const _calleeExtraWait = Duration(seconds: 25);
  bool _establishmentExtended = false;
  Timer? _restartWaitTimer;
  static const _restartWait = Duration(seconds: 12);
  bool _restartWaited = false;
  // Candidates gathered for the current local description, by type.
  final Map<String, int> _roundGathered = {};

  /// "RTCIceConnectionState.RTCIceConnectionStateChecking" -> "checking".
  static String _stateName(Object state, String prefix) =>
      state.toString().split('.').last.replaceFirst(prefix, '').toLowerCase();

  /// What each side could be reached by - the first thing to read on a
  /// connection that failed: no relay on either side on mobile data is
  /// a call that cannot connect.
  Map<String, Object?> _iceCounts() => {
        'host': _roundGathered['host'] ?? 0,
        'srflx': _roundGathered['srflx'] ?? 0,
        'relay': _roundGathered['relay'] ?? 0,
        'received_relay': diagnostics.received['relay'] ?? 0,
        'count': diagnostics.received.values.fold<int>(0, (a, b) => a + b),
        'turn': _turnConfigured,
      };

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
    ..._transportPolicy,
  };

  // One transport for audio and video (max-bundle) with RTCP on it, and
  // ICE candidates gathered the moment the peer connection exists (a pool
  // of one) rather than only once an offer or answer is set: fewer
  // candidates to try, found sooner - most of all the TURN relay's, the
  // slowest to gather and the one mobile data usually needs. Every
  // configuration carries the same three, because changing any of them on
  // a live connection (the ICE-restart refresh) is refused.
  static const Map<String, dynamic> _transportPolicy = {
    'bundlePolicy': 'max-bundle',
    'rtcpMuxPolicy': 'require',
    'iceCandidatePoolSize': 1,
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

  // ── Answering without "Connecting…" (CALLING.md, 2026-11-09) ─────────────
  // After Accept, the callee's phone used to open its socket, join, wait
  // for `ready`, take the offer, answer, and only then run ICE and DTLS:
  // five or six round trips on mobile data, 3-5 seconds of "Connecting…".
  // Now, while a voice call rings on the in-app screen, this phone waits in
  // the call's room (/calls/ws/{room}/ringing, a "standby" socket) and the
  // call is negotiated then: the caller sends its offer on `ringing_ready`,
  // this phone answers with no microphone open, and the connection comes up
  // while it rings. Nothing can be heard either way before Accept - this
  // phone has no microphone track and plays nothing it receives, and the
  // caller's microphone is held (its track disabled) until the server's
  // `ready` names this phone as the one that answered. Accept is one frame
  // on a socket that is already there.
  //
  // Whatever goes wrong on the way - the socket, the connection, a server
  // without the route or with it switched off (close 4010) - drops back to
  // the old way without a word: Accept then joins the call as it always
  // did. Nothing here may change the call's state while it rings: the call
  // screen stops the ringtone on any change (VoipCallScreen.onStateChange).

  /// Whether a phone may answer while ringing: Android's in-app ringing
  /// screen. Null asks the platform; tests set it.
  @visibleForTesting
  static bool? debugPreconnectSupported;

  /// Stand-ins for the native peer connection, the microphone and the
  /// signalling socket, for the tests of the above.
  @visibleForTesting
  static Future<RTCPeerConnection> Function(Map<String, dynamic> config)?
      debugCreatePeerConnection;
  @visibleForTesting
  static Future<MediaStream> Function(Map<String, dynamic> constraints)?
      debugGetUserMedia;
  @visibleForTesting
  static WebSocketChannel Function(Uri uri)? debugConnectSocket;

  static bool get _preconnectSupported =>
      debugPreconnectSupported ?? (!kIsWeb && Platform.isAndroid);

  static Future<RTCPeerConnection> _nativePc(Map<String, dynamic> config) {
    final seam = debugCreatePeerConnection;
    return seam != null ? seam(config) : createPeerConnection(config);
  }

  static Future<MediaStream> _openMedia(Map<String, dynamic> constraints) {
    final seam = debugGetUserMedia;
    return seam != null
        ? seam(constraints)
        : navigator.mediaDevices.getUserMedia(constraints);
  }

  static WebSocketChannel _openSocket(Uri uri) {
    final seam = debugConnectSocket;
    return seam != null ? seam(uri) : WebSocketChannel.connect(uri);
  }

  // Callee.
  bool _preconnectStarted = false;
  // In the room while it rings, not answered yet.
  bool _standby = false;
  // This phone's id for what it negotiated while ringing: the server names
  // it in `ready`, so the caller knows the phone that answered is this one.
  String? _peerId;
  // The caller's audio, received while ringing, plays only after Accept.
  bool _holdRemote = false;
  final List<MediaStreamTrack> _heldRemoteTracks = [];
  // Accepted, and the microphone is still opening: the call is connected
  // once it is on, not before.
  bool _attachingMedia = false;
  // The offer this phone last answered.
  String? _answeredOfferId;
  // Offers are answered one at a time (_queueOffer).
  Future<void> _offerQueue = Future<void>.value();
  int _offersInHand = 0;
  String? _offerIdBeforePc;

  // Caller.
  // The callee's phone the offer went to while it rang.
  String? _standbyPeer;
  // The microphone held until that phone answers.
  bool _mediaHeld = false;
  // The server's `ready`: the callee has joined the call. Until then the
  // call is unanswered - whatever was negotiated with a ringing phone.
  bool _calleeJoined = false;
  // Names the current offer; an answer naming another is stale.
  String? _offerId;
  int _offerSeq = 0;
  // A peer connection being replaced (_resetPreconnect).
  Future<void>? _resetting;

  // Both.
  bool _transportUp = false;
  RTCPeerConnectionState? _pcState;
  // Bumped whenever the peer connection is replaced: callbacks of the one
  // before go quiet.
  int _pcGen = 0;
  Map<String, dynamic>? _pcConfig;

  /// A connected peer connection is still only the call being prepared:
  /// the callee's phone still rings (or its microphone is opening), or the
  /// caller waits for that phone to answer.
  bool get _preconnecting =>
      isCaller ? _mediaHeld : (_standby || _attachingMedia);

  @visibleForTesting
  bool get debugStandby => _standby;
  @visibleForTesting
  bool get debugMediaHeld => _mediaHeld;
  @visibleForTesting
  String? get debugPeerId => _peerId;

  // ── Events for the logs ───────────────────────────────────────────────────

  /// The states every event carries (call_diagnostics.dart).
  Map<String, Object?> _states() => {
        'call_state': _state.name,
        'ws': _wsState,
        'ice_gathering': _iceGatheringName,
        'ice': _iceConnectionName,
        'pc': _pcStateName,
        'path': _path,
      };

  /// One event: to Render over the call's socket (or queued for it), and
  /// to logcat as it always was.
  void _event(String name, {String? reason, Object? error,
      Map<String, Object?> extra = const {}, bool terminal = false}) {
    final e = diagnostics.record(name, _states(),
        reason: reason, error: error, extra: extra, terminal: terminal);
    debugPrint('WebRTC: $name room=$roomId role=${diagnostics.role} '
        'state=${_state.name} ws=$_wsState ice=$_iceConnectionName pc=$_pcStateName'
        '${reason != null ? ' reason=$reason' : ''}'
        '${e['error'] != null ? ' error=${e['error']}' : ''}');
  }

  bool _sendDiag(Map<String, dynamic> frame) {
    final ws = _ws;
    if (ws == null || _wsState != 'open') return false;
    ws.sink.add(jsonEncode(frame));
    return true;
  }

  // ── Public API ────────────────────────────────────────────────────────────

  /// What the call needs from the network, fetched ahead of start() - the
  /// call screen calls this while the phone rings. Accept used to start the
  /// TURN credential request only once the microphone was open: a round
  /// trip (three, with a session that expired while the app was closed)
  /// added to every answered call's "Connecting".
  ///
  /// The peer connection itself is made here too (2026-10-12): with a
  /// candidate pool it starts gathering - the TURN relay's allocation, the
  /// slowest step and the one mobile data usually needs - while the phone
  /// rings. Made on Accept, that gathering sat between the callee's answer
  /// and "connected", and the callee watched "Connecting…" for it.
  void prepare() {
    final iceConfig = _iceConfigFuture ??= _fetchIceConfiguration();
    _preparedPc ??= iceConfig
        .then<RTCPeerConnection?>((config) => _nativePc(config))
        .catchError((Object e) {
      // start() makes one then, as it did before.
      debugPrint('WebRTC: could not prepare the peer connection: $e');
      return null;
    });
  }

  /// The callee's in-app ringing screen: what prepare() does, and the call
  /// negotiated while it rings (see the block above), where this phone can.
  /// Nothing is heard or shown before start(); a phone that can't, or a
  /// server that won't, answers the old way on Accept.
  void prepareRinging() {
    prepare();
    if (isCaller || isVideo || _preconnectStarted || !_preconnectSupported) return;
    if (_state != CallState.idle) return;
    _preconnectStarted = true;
    _standby = true;
    _holdRemote = true;
    _peerId = _newPeerId();
    unawaited(_openStandby());
  }

  static String _newPeerId() =>
      'p${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}'
      '${Random().nextInt(0x7fffffff).toRadixString(36)}';

  /// The peer connection, with no microphone, then the ringing socket.
  Future<void> _openStandby() async {
    final gen = _generation;
    try {
      final config = await (_iceConfigFuture ??= _fetchIceConfiguration());
      if (gen != _generation || !_standby) return;
      final pc = await _newPc(config);
      if (pc == null) return;
      if (gen != _generation || !_standby) {
        try { await pc.close(); } catch (_) {}
        return;
      }
      _pc = pc;
      _event('PRECONNECT_STARTED', extra: {'peer': _peerId, 'standby': true});
      await _connectWs(ringing: true);
    } catch (e) {
      debugPrint('WebRTC: could not wait in the call while it rings: $e');
      if (gen == _generation) _abandonPreconnect(reason: 'standby_failed', error: e);
    }
  }

  /// Back to the old way: the ringing socket and its connection go, and
  /// Accept joins the call as it did before. No state change - the phone
  /// is still ringing.
  void _abandonPreconnect({String reason = 'standby_closed', Object? error}) {
    if (!_standby) return;
    _event('PRECONNECT_ABANDONED', reason: reason, error: error);
    _standby = false;
    _peerId = null;
    // The socket's own close must not read as a dropped call to reconnect.
    _wsEpoch++;
    _wsWatchdogTimer?.cancel();
    _wsState = 'none';
    final ws = _ws;
    _ws = null;
    unawaited(_wsSub?.cancel());
    _wsSub = null;
    try { ws?.sink.close(); } catch (_) {}
    _pcGen++;
    final pc = _pc;
    _pc = null;
    if (pc != null) unawaited(pc.close().catchError((Object _) {}));
    _remoteDescriptionSet = false;
    _lastLocalAnswer = null;
    _answeredOfferId = null;
    _offerBeforePc = null;
    _offerIdBeforePc = null;
    _pendingIce.clear();
    _transportUp = false;
    _pcState = null;
    _heldRemoteTracks.clear();
    _holdLocalIce = false;
    _applyingRemote = false;
    _remoteUfrag = null;
    _sentLocalIce.clear();
    _localIceBeforePeer.clear();
    _iceGatheringName = 'new';
    _iceConnectionName = 'new';
    _pcStateName = 'new';
    // The old way connects after Accept: nothing of it is held.
    _holdRemote = false;
  }

  /// Accept, on a phone that waited in the room: one `accept` frame joins
  /// the call, and the microphone goes onto the connection made while it
  /// rang. Connected as soon as it is on, when the connection is already up.
  Future<void> _startPreconnected() async {
    final gen = _generation;
    _connectingStartedAt = DateTime.now();
    _standby = false;
    _attachingMedia = true;
    _setState(CallState.connecting);
    _event('CALL_ACCEPTED', extra: {
      'standby': true, 'answered': _remoteDescriptionSet, 'connected': _transportUp,
    });
    try {
      _ws?.sink.add(jsonEncode({'type': 'accept', 'room_id': roomId}));
    } catch (e) {
      // The socket is going: its reconnect joins the call the old way.
      debugPrint('WebRTC: could not send accept: $e');
    }
    try {
      debugPrint('WebRTC: LOCAL_MEDIA_REQUESTED room=$roomId');
      await _initMedia();
      if (gen != _generation) return;
      _event('LOCAL_MEDIA_READY');
      onLocalMediaReady?.call();
      await _attachMicrophone();
      if (gen != _generation) return;
      _attachingMedia = false;
      _releaseRemoteMedia();
      if (_transportUp) {
        _event('PRECONNECT_USED', extra: {'connected': true});
        _onPeerConnected();
      } else {
        // Negotiated, or about to be: the connection comes up on its own,
        // within the connect timeout `ringing` arms - and with no offer in
        // yet (the caller is not in the room), that timeout is the
        // no-offer one: nobody waits on an empty room.
        _setState(CallState.ringing);
      }
    } catch (e) {
      _attachingMedia = false;
      if (gen == _generation) _fail('Could not start call: $e', code: 'media_failed', error: e);
    }
  }

  /// The microphone onto the call. An answer made while it rang left the
  /// audio sender empty (_answerWithMicrophoneSlot): the track goes there,
  /// and no second negotiation is needed. Before any offer it goes in as
  /// any call's microphone does, and the offer is answered with it.
  Future<void> _attachMicrophone() async {
    final pc = _pc;
    final local = _local;
    if (pc == null || local == null) return;
    final audio = local.getAudioTracks();
    if (audio.isEmpty) return;
    final mic = audio.first;
    try {
      for (final t in await pc.getTransceivers()) {
        final kind = t.receiver.track?.kind;
        if (kind != null && kind != 'audio') continue;
        if (t.sender.track != null) return;
        await t.sender.replaceTrack(mic);
        if (await t.getDirection() == TransceiverDirection.RecvOnly) {
          await t.setDirection(TransceiverDirection.SendRecv);
        }
        debugPrint('WebRTC: LOCAL_AUDIO_TRACK_ATTACHED room=$roomId (answered while ringing)');
        return;
      }
      await pc.addTrack(mic, local);
      debugPrint('WebRTC: LOCAL_AUDIO_TRACK_ADDED room=$roomId');
    } catch (e) {
      debugPrint('WebRTC: could not put the microphone on the call: $e');
    }
  }

  /// The caller's audio, held while it rang, plays.
  void _releaseRemoteMedia() {
    _holdRemote = false;
    for (final t in _heldRemoteTracks) {
      try { t.enabled = true; } catch (_) {}
    }
    _heldRemoteTracks.clear();
  }

  /// Caller: the microphone held - or let go - for a phone that is still
  /// ringing. Mute still applies on top.
  void _holdMedia(bool held) {
    _mediaHeld = held;
    for (final t in _local?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      try { t.enabled = !held && !_muted; } catch (_) {}
    }
  }

  Future<Map<String, dynamic>>? _iceConfigFuture;
  Future<RTCPeerConnection?>? _preparedPc;

  /// The connection prepare() made, handed over once - or closed, when the
  /// call ends without it.
  Future<RTCPeerConnection?> _takePreparedPc() async {
    final prepared = _preparedPc;
    _preparedPc = null;
    return prepared == null ? null : await prepared;
  }

  /// Start: get mic/camera → open WebSocket → create peer connection.
  /// Caller then sends an offer; callee waits for one.
  Future<void> start() async {
    if (!isCaller && _standby) {
      // Waited in the room while it rang: answered on that socket. Not
      // there yet (Accept within a second of the ring), the old way.
      if (_pc != null && _ws != null) return _startPreconnected();
      _abandonPreconnect();
    }
    final gen = _generation;
    _connectingStartedAt = DateTime.now();
    _setState(CallState.connecting);
    _event(isCaller ? 'CALL_INITIATED' : 'CALL_ACCEPTED', extra: {'video': isVideo});
    // The relay credentials come over the network while the microphone
    // opens, not after it.
    final iceConfig = _iceConfigFuture ?? _fetchIceConfiguration();
    _iceConfigFuture = null;
    try {
      // The callee's way into the call opens while its microphone does:
      // the caller's offer can then arrive before the peer connection
      // exists, and waits for it (_offerBeforePc). Not while a permission
      // dialog is up - the caller's connect timeout would run on it.
      if (!isCaller && await _mediaPermissionsGranted()) {
        debugPrint('WebRTC: WEBSOCKET_CONNECTING room=$roomId (with media)');
        await _connectWs();
        if (gen != _generation) return;
      }
      if (isVideo) {
        await localRenderer.initialize();
        await remoteRenderer.initialize();
        _renderersReady = true;
      }
      debugPrint('WebRTC: LOCAL_MEDIA_REQUESTED room=$roomId');
      try {
        await _initMedia();
      } catch (e) {
        if (gen == _generation) _fail('Could not start call: $e', code: 'media_failed', error: e);
        return;
      }
      if (gen != _generation) return;
      _event('LOCAL_MEDIA_READY');
      onLocalMediaReady?.call();
      await _createPc(await iceConfig);
      if (gen != _generation) return;
      if (_ws == null) {
        debugPrint('WebRTC: WEBSOCKET_CONNECTING room=$roomId');
        await _connectWs();
        if (gen != _generation) return;
      }
      // NOTE: the caller must NOT send its SDP offer here - at this point the
      // room may still be empty (the callee hasn't joined). An offer sent now
      // is relayed to nobody and lost, leaving the call stuck on "Calling…".
      // Instead we wait for the backend's "ready" signal (fired once BOTH
      // peers are in the room) and send the offer from _onSignal(). We only
      // flip the UI to "calling" so the caller sees feedback immediately.
      if (isCaller) {
        _setState(CallState.calling);
        // The offer is MADE now, though: their phone rings for seconds, and
        // that is when this phone gathers its ways to be reached (ICE, the
        // TURN relay). It used to start on "ready", after they answered, and
        // every answered call waited for it on "Connecting".
        unawaited(_localOffer());
      } else {
        final early = _offerBeforePc;
        final earlyId = _offerIdBeforePc;
        _offerBeforePc = null;
        _offerIdBeforePc = null;
        if (early != null) {
          _queueOffer(early, isRestart: false, offerId: earlyId);
        } else if (_state == CallState.connecting) {
          // Answered, the microphone open, and no offer yet. It used to
          // wait here with no timer at all: a callee who answered a call
          // whose caller had gone (2026-11-13) sat on "Connecting…" until
          // someone hung up. The offer has this long to come.
          _armConnectTimeout();
        }
      }
    } catch (e) {
      if (gen == _generation) _fail('Could not start call: $e', code: 'setup_failed', error: e);
    }
  }

  Future<bool> _mediaPermissionsGranted() async {
    try {
      if (!await Permission.microphone.isGranted) return false;
      return !isVideo || await Permission.camera.isGranted;
    } catch (_) {
      return false;
    }
  }

  Future<void> hangup() async {
    // Deliver the hangup BEFORE tearing the socket down, and give the event
    // loop a beat to actually flush it. _cleanup() closes the sink, and a
    // close racing an add() on the same turn can discard the queued frame -
    // which the peer experiences as the call simply going quiet until its
    // own timeout fires, rather than ending cleanly.
    //
    // Not from a phone still ringing: it hasn't joined the call, and the
    // server only closes its socket on it - a decline is recorded through
    // POST /calls/log-result, which tells the caller.
    if (_state != CallState.ended && _state != CallState.failed) {
      _event('CALL_ENDED', reason: 'local_hangup', terminal: true, extra: {
        'connected': _everConnected, 'standby': _standby,
        'duration_s': _everConnected ? _duration.inSeconds : null,
      });
    }
    // The server closes this socket as soon as it has the hangup - inside
    // the beat below - and that close is the call ending, not a drop to
    // reconnect from.
    _endingLocally = true;
    if (!_standby) {
      try {
        _ws?.sink.add(jsonEncode({'type': 'hangup', 'room_id': roomId}));
        await Future<void>.delayed(const Duration(milliseconds: 60));
      } catch (e) {
        debugPrint('WebRTC: could not send hangup: $e');
      }
    }
    await _cleanup();
    _setState(CallState.ended);
  }

  void toggleMute() {
    _muted = !_muted;
    // A microphone held for a phone still ringing stays held.
    _local?.getAudioTracks().forEach((t) => t.enabled = !_muted && !_mediaHeld);
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
    for (final t in _localVideoTracks) {
      t.enabled = _videoEnabled;
    }
    _sendVideoState();
  }

  // The camera's tracks, whether it opened with the call or mid-call.
  List<MediaStreamTrack> get _localVideoTracks => [
        ...?_local?.getVideoTracks(),
        ...?_camera?.getVideoTracks(),
      ];

  /// Whether this side is sending a picture (its camera is open, even if
  /// turned off for now).
  bool get hasCamera => _localVideoTracks.isNotEmpty;

  // ── Switching a voice call to video ───────────────────────────────────────

  // The camera opened mid-call by upgradeToVideo. Its own stream, disposed
  // with the call: moving its track into the call's stream would leave two
  // streams disposing one track.
  MediaStream? _camera;
  Future<void>? _videoReady;
  bool _renegotiationQueued = false;

  /// Turn this side's camera on during a call: a voice call becomes a
  /// video call, as on WhatsApp. Opens the camera, adds it to the call and
  /// has the call renegotiated so the other side receives it - their call
  /// screen turns into a video call too, with their own camera off until
  /// they turn it on.
  ///
  /// Returns null when the camera is on, or what to tell the user.
  Future<String?> upgradeToVideo() async {
    if (_pc == null || _state != CallState.connected) {
      return 'You can turn your camera on once the call has connected.';
    }
    if (hasCamera) {
      if (!_videoEnabled) toggleVideo();
      return null;
    }
    final gen = _generation;
    try {
      if (!await Permission.camera.request().isGranted) {
        return 'BROKA needs camera access for video. '
            'Enable it in Settings > Apps > BROKA > Permissions.';
      }
    } catch (_) {
      // permission_handler misbehaving: getUserMedia will say if it's real.
    }
    if (gen != _generation || _pc == null) return null;
    MediaStream camera;
    try {
      camera = await navigator.mediaDevices.getUserMedia(
          {'audio': false, 'video': _videoConstraints});
    } catch (e) {
      debugPrint('WebRTC: camera unavailable mid-call: $e');
      return "Couldn't open the camera.";
    }
    final tracks = camera.getVideoTracks();
    if (gen != _generation || _pc == null || tracks.isEmpty) {
      await _disposeStream(camera);
      return tracks.isEmpty ? "Couldn't open the camera." : null;
    }
    _camera = camera;
    _cameraDenied = false;
    _videoEnabled = true;
    await _becomeVideo();
    if (gen != _generation || _pc == null) return null;
    // On to the speaker: a picture is watched with the phone held in front,
    // not at the ear - a call that starts as video starts on speaker too.
    // Only for this side's own camera: the other side turning theirs on
    // must not put this phone, maybe at someone's ear, on the loudspeaker.
    if (!_speaker) {
      try {
        await Helper.setSpeakerphoneOn(true);
        _speaker = true;
      } catch (e) {
        debugPrint('WebRTC: speaker on for video failed: $e');
      }
    }
    localRenderer.srcObject = camera;
    try {
      // Same stream id as the call's audio, so the other side sees one
      // stream with both.
      await _pc!.addTrack(tracks.first, _local ?? camera);
    } catch (e) {
      debugPrint('WebRTC: could not add the camera to the call: $e');
      return "Couldn't start video.";
    }
    debugPrint('WebRTC: LOCAL_VIDEO_TRACK_ADDED room=$roomId (mid-call)');
    _sendVideoState();
    await _renegotiate();
    return null;
  }

  /// The call becomes a video call on this side: renderers up and the
  /// screen told. Once, whichever of the two ways got here first.
  Future<void> _becomeVideo() => _videoReady ??= () async {
        if (!_renderersReady) {
          await localRenderer.initialize();
          await remoteRenderer.initialize();
          _renderersReady = true;
        }
        if (_callType == 'video') return;
        _callType = 'video';
        debugPrint('WebRTC: CALL_BECAME_VIDEO room=$roomId');
        onCallTypeChanged?.call('video');
      }();

  /// A fresh offer for a call already under way: a camera was added.
  ///
  /// Only the caller offers. Two offers crossing (both sides turning their
  /// cameras on at once) would leave each waiting for an answer to its own
  /// - so the callee asks the caller for one ('renegotiate', relayed by the
  /// server) and answers it. Sent flagged `restart`, the flag every build,
  /// this one and those before it, answers mid-call instead of discarding
  /// as a repeat of the call's first offer.
  Future<void> _renegotiate() async {
    if (!isCaller) {
      try {
        _ws?.sink.add(jsonEncode({'type': 'renegotiate', 'room_id': roomId}));
      } catch (_) {}
      return;
    }
    if (_pc == null) return;
    if (_awaitingRestartAnswer || _iceRestartInProgress) {
      // One at a time: this runs again once the pending answer is in.
      _renegotiationQueued = true;
      return;
    }
    final gen = _generation;
    try {
      final offer = await _pc!.createOffer(
          {'offerToReceiveAudio': true, 'offerToReceiveVideo': true});
      if (gen != _generation || _pc == null) return;
      final tuned = _tuneSdp(offer);
      _beginLocalDescription();
      await _pc!.setLocalDescription(tuned);
      _lastLocalOffer = tuned;
      _awaitingRestartAnswer = true;
      if (gen != _generation || _ws == null) return;
      _ws!.sink.add(jsonEncode({
        'type': 'offer', 'room_id': roomId, 'sdp': tuned.sdp,
        'restart': true, 'renegotiate': true,
      }));
      _descriptionSent();
      debugPrint('WebRTC: RENEGOTIATION_OFFER_SENT room=$roomId');
    } catch (e, st) {
      // The call goes on as it was: a camera that couldn't be added is no
      // reason to end it.
      _holdLocalIce = false;
      debugPrint('WebRTC: renegotiation failed: $e\n$st');
    }
  }

  /// A new local description is about to be set: its candidates wait until
  /// it has been sent (see _holdLocalIce), and the last one's are done with.
  void _beginLocalDescription() {
    _holdLocalIce = true;
    _sentLocalIce.clear();
    _roundGathered.clear();
    // Held for a description this one replaces (never sent - the socket
    // was down): they belong to an ICE session that is over.
    _localIceBeforePeer.clear();
  }

  /// The local description just went to the other phone: its candidates
  /// follow it.
  void _descriptionSent() {
    _holdLocalIce = false;
    _flushLocalIce();
  }

  Future<void> _disposeStream(MediaStream stream) async {
    try {
      for (final t in stream.getTracks()) {
        await t.stop();
      }
      await stream.dispose();
    } catch (_) {}
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
    if (!isVideo) return;
    final tracks = _localVideoTracks;
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

  /// [ringing]: the callee's standby socket, while its phone rings.
  Future<void> _connectWs({bool ringing = false}) async {
    const raw  = ApiService.baseUrl;
    final base = raw.startsWith('https://')
        ? raw.replaceFirst('https://', 'wss://')
        : raw.replaceFirst('http://', 'ws://');
    // Short-lived, room-scoped call_token (from POST /calls/initiate or
    // GET /calls/pending/{listingId} / /calls/{roomId}/token) - not the
    // normal long-lived access token, which used to sit in this URL where
    // it could end up in proxy/server access logs. `peer` names what this
    // phone negotiated while ringing, for the server's `ready`.
    final peer = _peerId;
    final uri = Uri.parse('$base/calls/ws/$roomId${ringing ? '/ringing' : ''}'
        '?token=$_callToken${peer == null ? '' : '&peer=$peer'}');

    // Retire the previous socket explicitly before standing up a new one.
    // Bumping the epoch is what makes the old subscription's callbacks
    // inert (see _wsEpoch); closing it releases the native socket instead
    // of leaving it dangling until GC. Its subscription goes too, so
    // nothing of the old socket outlives it.
    final previous = _ws;
    final epoch = ++_wsEpoch;
    unawaited(_wsSub?.cancel());
    _wsSub = null;
    if (previous != null) {
      try { previous.sink.close(); } catch (_) {}
    }

    final ws = _openSocket(uri);
    _ws = ws;
    // Open only once the server has said something on it (_onSignal):
    // WebSocketChannel.connect is lazy, and a socket refused at the
    // handshake looks writable until then.
    _wsState = 'connecting';
    _wsSub = ws.stream.listen(
      (raw) => _onSignal(raw, epoch),
      onError: (e) { if (epoch == _wsEpoch) _onWsDisrupted('Signal error: $e'); },
      onDone:  ()  { if (epoch == _wsEpoch) _onWsClosed(ws.closeCode, ws.closeReason); },
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

  /// Caller: the callee has answered and joined (the server's `ready`).
  /// From here a slow start is negotiation, not "no answer". Not an offer
  /// having gone out: that now happens while their phone still rings.
  bool get peerJoined => _calleeJoined;

  /// A signalling frame as if the server had sent it - for tests.
  @visibleForTesting
  void debugReceiveSignal(String raw) => _onSignal(raw);

  void _onSignal(dynamic raw, [int? epoch]) {
    if (epoch != null && epoch != _wsEpoch) return; // superseded socket
    _armWsWatchdog();
    if (epoch != null && _wsState != 'open') {
      // The first frame the server sent on this socket: it is up end to
      // end. What waited for a socket goes now.
      _wsState = 'open';
      _tokenRefreshTried = false;
      final again = _everOpenedSocket;
      _everOpenedSocket = true;
      _socketReportedEpoch = null;
      _event(again ? 'WEBSOCKET_RECONNECTED' : 'WEBSOCKET_CONNECTED',
          extra: {'epoch': epoch, 'standby': _standby, 'attempt': _reconnectAttempts});
      diagnostics.flushOverSocket();
    }
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
            unawaited(_onCallerReady(m['peer'] as String?));
          } else {
            _event('PEER_JOINED', extra: {'answered': _lastLocalAnswer != null});
            if (_state == CallState.connected) _reportWebRtcState('connected');
            // Not while an offer is being answered: that answer, and its
            // candidates, go when it is made.
            if (_lastLocalAnswer != null && _offersInHand == 0) {
              // Callee side: we already answered once - resend in case it
              // never reached the caller before signaling dropped, and the
              // candidates that followed it.
              _resendAnswer();
              _resendLocalIce();
            }
          }
          break;
        case 'push_status':
          // Server-authored: the push to their phone finished after the
          // call was placed - and could not be delivered.
          if (isCaller) onPushStatus?.call(m['status'] as String? ?? '');
          break;
        case 'ringing_ready':
          // Server-authored: a phone of the callee's is in the room while
          // it rings - negotiate with it now.
          if (isCaller) unawaited(_onRingingReady(m['peer'] as String?));
          break;
        case 'ringing_left':
          // Server-authored: that phone's socket went before it answered.
          if (isCaller) _onRingingLeft(m['peer'] as String?);
          break;
        case 'offer':
          _queueOffer(m['sdp'] as String,
              isRestart: m['restart'] == true, offerId: m['offer_id'] as String?);
          break;
        case 'renegotiate':
          // The callee turned its camera on and needs an offer that carries
          // it - only the caller offers (see _renegotiate).
          if (isCaller && _remoteDescriptionSet) unawaited(_renegotiate());
          break;
        case 'answer':
          _handleAnswer(m['sdp'] as String,
              isRestart: m['restart'] == true, offerId: m['offer_id'] as String?);
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
          // call. Only meaningful while we're still waiting for an answer -
          // not answered yet, however far a ringing phone has negotiated.
          if (isCaller && !_calleeJoined &&
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
          // Somebody ended the call - deliberately (the peer's own hangup,
          // the server relaying a decline or deciding nobody answered), or
          // because their connection never came up (`failed`, 2026-11-13:
          // the other side used to wait on "Connecting…" for it).
          remoteEndReason = m['reason'] as String?;
          _event('CALL_ENDED', reason: 'remote_${remoteEndReason ?? 'hangup'}',
              terminal: true, extra: {
                'connected': _everConnected, 'standby': _standby,
                'duration_s': _everConnected ? _duration.inSeconds : null,
              });
          _cleanup();
          _setState(CallState.ended);
          break;
        case 'busy':
          // Turned away while it rings: the old way, on Accept.
          if (_standby) {
            _abandonPreconnect(reason: 'busy');
            break;
          }
          if (_reconnectAttempts > 0 && _reconnectAttempts < _maxReconnectAttempts) {
            // Mid-reconnect: the server may not have reaped our previous
            // socket yet. Failing the call outright here would throw away
            // a call that's about to be perfectly recoverable - back off
            // and try again instead.
            debugPrint('WebRTC: busy during reconnect - retrying');
            _scheduleReconnect();
            break;
          }
          _fail('Other party is busy', code: 'busy');
          break;
        case 'error':
          if (_standby) {
            _abandonPreconnect(reason: 'signaling_error');
            break;
          }
          _fail(m['message'] as String? ?? 'Unknown signaling error', code: 'signaling_error');
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
    _event('PEER_SIGNALING_LOST', extra: {'ms': _peerRecoveryTimeout.inMilliseconds});
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
      _fail('The other person lost connection', code: 'peer_lost');
    });
  }

  void _onPeerSignalingRestored() {
    if (!_peerSignalingDown) return;
    _peerSignalingDown = false;
    _peerRecoveryTimer?.cancel();
    _peerRecoveryTimer = null;
    _event('PEER_SIGNALING_RESTORED');
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
  /// The server's close code for "your call token is not (or no longer)
  /// good" (api/routers/calls.py: "Unauthorized").
  static const int unauthorizedCloseCode = 4001;

  // Set by hangup(): the socket closing now is this phone's own doing.
  bool _endingLocally = false;

  void _onWsClosed(int? code, [String? closeReason]) {
    if (_endingLocally) return;
    _reportSocketDown(code: code, closeReason: closeReason);
    final neverConnected = _state == CallState.idle ||
        _state == CallState.connecting || _state == CallState.calling ||
        _state == CallState.ringing;
    if (code == callOverCloseCode && neverConnected) {
      remoteEndReason = 'call_over';
      _event('CALL_ENDED', reason: 'call_over', terminal: true,
          extra: {'code': code, 'standby': _standby});
      _cleanup();
      _setState(CallState.ended);
      return;
    }
    // A ringing phone's socket: refused (4010 - switched off, or no longer
    // ringing), replaced by another phone of theirs (4009), or dropped.
    // Not reconnected - Accept takes the old way.
    if (_standby) {
      _abandonPreconnect(reason: 'standby_closed_$code');
      return;
    }
    if (code == unauthorizedCloseCode && !_tokenRefreshTried &&
        _state != CallState.ended && _state != CallState.failed) {
      // The call token ran out (five minutes): a reconnect late in a call
      // was refused with it for good. One fresh token, then on as before.
      _tokenRefreshTried = true;
      unawaited(_reconnectWithFreshToken());
      return;
    }
    _onWsDisrupted(null);
  }

  Future<void> _reconnectWithFreshToken() async {
    final gen = _generation;
    final fresh = await ApiService.refreshCallToken(roomId);
    if (gen != _generation) return;
    if (fresh == null) {
      _onWsDisrupted('Call token could not be renewed');
      return;
    }
    _callToken = fresh;
    _event('WEBSOCKET_TOKEN_REFRESHED');
    _scheduleReconnect();
  }

  /// One WEBSOCKET_DISCONNECTED per socket, however it went (an error, then
  /// its close).
  void _reportSocketDown({int? code, String? closeReason, String? error}) {
    if (_socketReportedEpoch == _wsEpoch) return;
    _socketReportedEpoch = _wsEpoch;
    final was = _wsState;
    _wsState = 'closed';
    _event('WEBSOCKET_DISCONNECTED',
        reason: error != null ? 'error' : (was == 'open' ? 'closed' : 'refused_or_unreachable'),
        error: error,
        extra: {'code': code, 'close_reason': cleanDiagnosticText(closeReason, max: 60),
                'epoch': _wsEpoch, 'standby': _standby});
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
    if (_state == CallState.ended || _state == CallState.failed || _endingLocally) return;
    _reportSocketDown(error: errorMsg);
    if (_standby) {
      _abandonPreconnect(reason: 'standby_disrupted');
      return;
    }
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
      _fail(errorMsg ?? 'Connection lost - could not reconnect', code: 'signaling_lost');
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
    _wsState = 'reconnecting';
    _event('WEBSOCKET_RECONNECT_SCHEDULED', extra: {
      'attempt': _reconnectAttempts, 'max_attempts': _maxReconnectAttempts,
      'ms': delay.inMilliseconds,
    });
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(delay, () async {
      if (gen != _generation) return;
      if (_state == CallState.ended || _state == CallState.failed) return;
      try {
        await _connectWs();
      } catch (e) {
        if (gen == _generation) _onWsDisrupted('Reconnect failed: $e');
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

  /// [initial]: the connection never came up, and this is its one second
  /// try (see _initialRestarts) - not a recovery of a call that was up.
  Future<void> _attemptIceRestart({bool initial = false}) async {
    if (_iceRestartInProgress) return; // never run two restarts concurrently
    if (_pc == null) return;
    if (!initial && _iceRestartAttempts >= _maxIceRestartAttempts) {
      _fail('Connection could not recover after $_maxIceRestartAttempts attempt(s)',
          code: 'restart_failed');
      return;
    }
    _iceRestartInProgress = true;
    if (!initial) _iceRestartAttempts++;
    final gen = _generation;
    _event('ICE_RESTART_STARTED', reason: initial ? 'never_connected' : 'connection_lost', extra: {
      'attempt': initial ? _initialRestarts : _iceRestartAttempts,
      'max_attempts': initial ? _maxInitialRestarts : _maxIceRestartAttempts,
      'turn': _turnConfigured,
    });
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
            _pcConfig = freshConfig;
            _turnConfigured = true;
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
        _beginLocalDescription();
        await _pc!.setLocalDescription(tuned);
        _lastLocalOffer = tuned;
        // Tells _handleAnswer that the next answer is a legitimate
        // renegotiation, not a replayed duplicate to be discarded.
        _awaitingRestartAnswer = true;
        _event('SDP_OFFER_CREATED', extra: {'restart': true, ...sdpDirections(tuned.sdp)});
        if (gen != _generation || _ws == null) return;
        _ws!.sink.add(jsonEncode({
          'type': 'offer', 'room_id': roomId, 'sdp': tuned.sdp, 'restart': true,
        }));
        _descriptionSent();
        _event('SDP_OFFER_SENT', extra: {'restart': true});
      }
      // If we're still in `recovering` after another grace period (the
      // restart offer went out but negotiation hasn't completed, or -
      // callee side - no restart offer has arrived yet), arm another
      // grace window; onConnectionState's connected case resets
      // _iceRestartAttempts and cancels this the moment it actually works.
      // Not for a connection that never came up: the connect timeout,
      // extended for this try, decides that one.
      if (!initial) _armDisconnectGraceTimer();
    } catch (e, st) {
      _holdLocalIce = false;
      debugPrint('WebRTC: ICE restart failed: $e\n$st');
      if (gen == _generation) _fail('Could not restart the connection: $e', code: 'restart_failed', error: e);
    } finally {
      _iceRestartInProgress = false;
    }
  }

  /// Caller: one more try at a connection that never came up - ICE
  /// restarted with fresh relay credentials. Only once there is something
  /// to restart (their answer is in) and a socket to send it on.
  bool get _canRestartBeforeConnect =>
      isCaller && !_everConnected && _initialRestarts < _maxInitialRestarts &&
      _pc != null && _ws != null && _remoteDescriptionSet && !_preconnecting;

  void _restartBeforeConnect(String why) {
    _initialRestarts++;
    debugPrint('WebRTC: restarting ICE before the call ever connected ($why)');
    _armConnectTimeout(_restartWindow);
    unawaited(_attemptIceRestart(initial: true));
  }

  // ── SDP exchange ──────────────────────────────────────────────────────────

  // The caller's offer, made once: ahead of time while the callee's phone
  // rings (start), or on 'ready' if that had not finished.
  Future<RTCSessionDescription?>? _offerFuture;

  /// The offer for the current peer connection. One that could not be made
  /// is not kept: the next ask tries again. Kept, a failure - or an ask in
  /// the moment a connection is being replaced - made every later delivery
  /// fail the call with "Could not create call offer".
  Future<RTCSessionDescription?> _localOffer() {
    final cached = _offerFuture;
    if (cached != null) return cached;
    final made = _makeOffer();
    _offerFuture = made;
    unawaited(made.then((offer) {
      if (offer == null && identical(_offerFuture, made)) _offerFuture = null;
    }));
    return made;
  }

  Future<RTCSessionDescription?> _makeOffer() async {
    final gen = _generation;
    final pcGen = _pcGen;
    try {
      final pc = _pc;
      if (pc == null) return null;
      final offer = await pc.createOffer(
          {'offerToReceiveAudio': true, 'offerToReceiveVideo': isVideo});
      if (gen != _generation || pcGen != _pcGen) return null;
      final tuned = _tuneSdp(offer);
      // Starts ICE gathering: the candidates that come of it wait in
      // _localIceBeforePeer until the callee is in the room and this offer
      // has gone to it.
      _beginLocalDescription();
      await pc.setLocalDescription(tuned);
      if (gen != _generation || pcGen != _pcGen) return null;
      _lastLocalOffer = tuned; // cache for resend - see 'ready' handler in _onSignal
      // The answer to this offer names it; one naming another is stale.
      _offerId = '${++_offerSeq}-${Random().nextInt(0x7fffffff).toRadixString(36)}';
      _event('SDP_OFFER_CREATED', extra: {'offer_id': _offerId, ...sdpDirections(tuned.sdp)});
      return tuned;
    } catch (e, st) {
      // FORENSIC FIX (kept from _sendOffer): a failure in createOffer() or
      // setLocalDescription() - codec negotiation, a native platform-channel
      // error - must be caught and logged, never left an unhandled Future
      // rejection (which surfaced as "the app closes"). Delivery makes one
      // more attempt, then fails the call cleanly.
      if (pcGen == _pcGen) _holdLocalIce = false;
      _event('SDP_FAILED', reason: 'offer_failed', error: e);
      debugPrint('WebRTC: offer failed: $e\n$st');
      return null;
    }
  }

  /// Send the offer, and the candidates gathered for it while their phone
  /// rang: to the callee who joined (`ready`), or to their phone still
  /// ringing in the room (`ringing_ready`).
  Future<void> _deliverOffer() async {
    final gen = _generation;
    // A connection being replaced: the offer is the new one's.
    final resetting = _resetting;
    if (resetting != null) await resetting;
    if (gen != _generation) return;
    final pcGen = _pcGen;
    var offer = await _localOffer();
    if (gen != _generation || pcGen != _pcGen) return;
    offer ??= await _localOffer();
    if (gen != _generation || pcGen != _pcGen) return;
    if (offer == null) {
      if (!_calleeJoined) {
        // For a phone still ringing: nobody has answered, so nothing has
        // failed yet. The offer is tried again when they do (`ready`).
        debugPrint('WebRTC: no offer for the ringing phone - waiting for the answer');
        _standbyPeer = null;
        _holdMedia(false);
        return;
      }
      _fail('Could not create call offer', code: 'offer_failed');
      return;
    }
    if (_ws == null || _remoteDescriptionSet) return;
    try {
      _ws!.sink.add(jsonEncode({
        'type': 'offer', 'room_id': roomId, 'sdp': offer.sdp,
        if (_offerId != null) 'offer_id': _offerId,
      }));
      final held = _localIceBeforePeer.length;
      _descriptionSent();
      _event('SDP_OFFER_SENT', extra: {
        'offer_id': _offerId, 'count': held,
        'standby': _standbyPeer != null && !_calleeJoined,
      });
    } catch (e) {
      // The socket is going down; the reconnect's 'ready' sends it again.
      debugPrint('WebRTC: could not send offer: $e');
    }
  }

  /// Caller: a phone of the callee's waits in the room while it rings
  /// (`ringing_ready`). The offer goes to it now, with this phone's
  /// microphone held until it answers - so what used to follow Accept
  /// happens while it rings. Voice calls only: no camera is opened, or
  /// held, for a phone that hasn't answered.
  Future<void> _onRingingReady(String? peer) async {
    if (peer == null || peer.isEmpty || isVideo) return;
    if (_calleeJoined || _state != CallState.calling) return;
    if (_standbyPeer == peer) {
      // The same phone again: the offer, unless it has answered it.
      if (!_remoteDescriptionSet) unawaited(_deliverOffer());
      return;
    }
    if (_standbyPeer != null) {
      // Another phone of theirs: what was negotiated with the first is no
      // use to it.
      await _resetPreconnect(peerStillHere: true);
      if (_calleeJoined || _state != CallState.calling) return;
    }
    _standbyPeer = peer;
    _holdMedia(true);
    _peerInRoom = true;
    _event('PRECONNECT_STARTED', extra: {'peer': peer});
    unawaited(_deliverOffer());
  }

  /// Caller: the ringing phone's socket went before it answered. What was
  /// negotiated with it goes too; it, or another, answers the old way.
  void _onRingingLeft(String? peer) {
    if (_calleeJoined || peer == null || peer != _standbyPeer) return;
    _event('PRECONNECT_ABANDONED', reason: 'ringing_phone_left', extra: {'peer': peer});
    unawaited(_resetPreconnect(peerStillHere: false));
  }

  /// Caller: the server's `ready` - the callee has joined the call. When
  /// it is the phone this call was negotiated with while it rang, the
  /// microphone is let go and the call is through. Any other (another
  /// phone, or one that started afresh) gets a new offer on a new
  /// connection, as every call did before. Also fires again on a WS
  /// reconnect (server re-sends 'ready' once room membership reaches 2
  /// again), which is what makes resend-on-reconnect work: this is the ONE
  /// signal both sides can use to notice "signaling just came back"
  /// without a separate reconnect-specific message.
  Future<void> _onCallerReady(String? peer) async {
    final gen = _generation;
    final first = !_calleeJoined;
    _calleeJoined = true;
    _peerInRoom = true;
    // The callee has joined: from here the connect timeout applies, and
    // it is no longer ringing.
    if (first && _state == CallState.calling) _armConnectTimeout();
    if (first) onPeerJoined?.call();
    _event('PEER_JOINED', extra: {
      'peer': peer, 'standby': _standbyPeer != null, 'answered': _remoteDescriptionSet,
      'reconnects': first ? null : _reconnectAttempts,
    });
    // Back after a drop with the call up: the server hears it again, in
    // case that word was lost with the old socket.
    if (!first && _state == CallState.connected) _reportWebRtcState('connected');
    final negotiatedWith = _standbyPeer;
    _standbyPeer = null;
    _holdMedia(false);
    if (negotiatedWith != null && peer != negotiatedWith) {
      _event('PRECONNECT_ABANDONED',
          reason: peer == null ? 'answered_afresh' : 'answered_on_another_phone');
      await _resetPreconnect(peerStillHere: true);
      if (gen != _generation) return;
    } else if (negotiatedWith != null && _remoteDescriptionSet) {
      _event('PRECONNECT_USED', extra: {'connected': _transportUp});
      if (_transportUp) {
        _onPeerConnected();
      } else if (_pcState == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
        // Up once, gone since: a fresh path before anyone waits on it.
        unawaited(_attemptIceRestart());
      }
      // Otherwise still connecting: onConnectionState puts it through.
      return;
    }
    if (!_remoteDescriptionSet) {
      // The offer - made while their phone rang, or now - and the
      // candidates gathered for it. Again after a signalling reconnect, if
      // the callee never answered (most likely it never reached them): the
      // SAME sdp, never a fresh one - and its candidates again, since the
      // ones trickled meanwhile went down with the old socket.
      unawaited(_deliverOffer().then((_) {
        if (!first && gen == _generation) _resendLocalIce();
      }));
    } else if (_awaitingRestartAnswer && _lastLocalOffer != null) {
      // A restart or a camera being added was offered and its answer
      // never came back - lost with the socket that just reconnected.
      _ws?.sink.add(jsonEncode({
        'type': 'offer', 'room_id': roomId, 'sdp': _lastLocalOffer!.sdp,
        'restart': true,
      }));
      _descriptionSent();
      _resendLocalIce();
      _event('SDP_OFFER_SENT', extra: {'restart': true, 'reconnects': _reconnectAttempts});
    } else if (!first) {
      // Negotiated before the drop; the candidates may not have all made
      // it across.
      _resendLocalIce();
    }
  }

  /// Caller: a new peer connection, and a new offer made on it, in place of
  /// one negotiated with a ringing phone that won't be the one on the call.
  /// [peerStillHere]: someone is in the room to send the new one's
  /// candidates to.
  Future<void> _resetPreconnect({required bool peerStillHere}) {
    final before = _resetting ?? Future<void>.value();
    late final Future<void> run;
    run = before.then((_) async {
      final gen = _generation;
      final config = _pcConfig;
      _standbyPeer = null;
      _holdMedia(false);
      _transportUp = false;
      _pcState = null;
      _remoteDescriptionSet = false;
      _lastLocalOffer = null;
      _offerFuture = null;
      _offerId = null;
      _awaitingRestartAnswer = false;
      _pendingIce.clear();
      _localIceBeforePeer.clear();
      _sentLocalIce.clear();
      _holdLocalIce = false;
      _remoteUfrag = null;
      _applyingRemote = false;
      _peerInRoom = peerStillHere;
      _pcGen++;
      final old = _pc;
      _pc = null;
      try { await old?.close(); } catch (_) {}
      if (gen != _generation || config == null) return;
      await _createPc(config);
      if (gen != _generation) return;
      // Its candidates gather while it waits, as the first one's did.
      if (_state == CallState.calling) unawaited(_localOffer());
      debugPrint('WebRTC: PRECONNECT_RESET room=$roomId');
    }).catchError((Object e) {
      debugPrint('WebRTC: could not replace the peer connection: $e');
    }).whenComplete(() {
      if (identical(_resetting, run)) _resetting = null;
    });
    _resetting = run;
    return run;
  }

  /// Callee: this phone's answer again, for a caller that may not have it.
  void _resendAnswer() {
    final answer = _lastLocalAnswer;
    if (answer == null) return;
    try {
      _ws?.sink.add(jsonEncode({
        'type': 'answer', 'room_id': roomId, 'sdp': answer.sdp,
        if (_answeredOfferId != null) 'offer_id': _answeredOfferId,
      }));
      // An answer that never went (the socket was down as it was made):
      // its candidates were held for it, and follow it now.
      _descriptionSent();
      debugPrint('WebRTC: ANSWER_SENT room=$roomId (resend)');
    } catch (_) {}
  }

  // Caller: candidates gathered before the callee joined the room. The
  // server relays only to who is there, so they are held and sent right
  // after the offer they belong to.
  final List<String> _localIceBeforePeer = [];
  bool _peerInRoom = false;

  void _flushLocalIce() {
    if (_holdLocalIce || (isCaller && !_peerInRoom)) return;
    if (_localIceBeforePeer.isEmpty) return;
    final held = List<String>.from(_localIceBeforePeer);
    _localIceBeforePeer.clear();
    for (final frame in held) {
      _sentLocalIce.add(frame);
      try {
        _ws?.sink.add(frame);
      } catch (_) {}
    }
    debugPrint('WebRTC: ICE_CANDIDATES_SENT_AFTER_DESCRIPTION room=$roomId count=${held.length}');
  }

  /// Signalling is back after a drop: this phone's candidates go again -
  /// any trickled while a socket was down never arrived. Duplicates are
  /// ignored by the other side's ICE agent.
  void _resendLocalIce() {
    _flushLocalIce();
    if (_holdLocalIce || _sentLocalIce.isEmpty) return;
    for (final frame in _sentLocalIce) {
      try {
        _ws?.sink.add(frame);
      } catch (_) {}
    }
    debugPrint('WebRTC: ICE_CANDIDATES_RESENT room=$roomId count=${_sentLocalIce.length}');
  }

  // Callee: an offer that arrived before the peer connection existed (the
  // socket opens while the microphone does - see start). Answered as soon
  // as the peer connection is up.
  String? _offerBeforePc;

  @visibleForTesting
  String? get debugHeldOffer => _offerBeforePc;

  /// Offers are answered one at a time, in the order they came: two in
  /// flight at once - the caller resending its offer on `ready` while this
  /// phone was still answering it - set two answers on one connection, and
  /// the second failed the call. Run at once when nothing is in hand, so a
  /// held offer is held before the frame that brought it returns.
  void _queueOffer(String sdp, {required bool isRestart, String? offerId}) {
    Future<void> run() => _handleOffer(sdp, isRestart: isRestart, offerId: offerId);
    final next = _offersInHand == 0 ? run() : _offerQueue.then((_) => run());
    _offersInHand++;
    _offerQueue = next.catchError((Object e) {
      debugPrint('WebRTC: offer handling failed: $e');
    }).whenComplete(() {
      _offersInHand--;
    });
  }

  Future<void> _handleOffer(String sdp, {bool isRestart = false, String? offerId}) async {
    final gen = _generation;
    // Duplicate-offer guard (Section 8): once the remote description is
    // already set, a second 'offer' (a duplicated/replayed signaling
    // message) must not re-run the answer flow from scratch. A genuine
    // ICE-restart offer (Section 6) is the one deliberate exception - it's
    // a legitimate renegotiation, not a duplicate, so it's allowed through.
    // So is an offer naming another id: the caller started again, on a new
    // connection of its own (its first failed while this phone rang, or it
    // had negotiated with another phone), and this phone answers it on a
    // new one too.
    if (_remoteDescriptionSet && !isRestart) {
      final newer = offerId != null && _answeredOfferId != null && offerId != _answeredOfferId;
      if (!newer) {
        debugPrint('WebRTC: ignoring duplicate offer');
        // The caller resends its offer only while it has no answer: that
        // one was lost on the way.
        _resendAnswer();
        return;
      }
      debugPrint('WebRTC: NEW_OFFER room=$roomId (the caller started again)');
      if (!await _rebuildForNewOffer() || gen != _generation) return;
    }
    if (_pc == null) {
      // Ahead of our peer connection: answered once it exists (start).
      if (!isRestart) {
        _offerBeforePc = sdp;
        _offerIdBeforePc = offerId;
      }
      debugPrint('WebRTC: OFFER_HELD room=$roomId (peer connection not ready)');
      return;
    }
    final pc = _pc!;
    final pcGen = _pcGen;
    bool stale() => gen != _generation || pcGen != _pcGen;
    // Answered while it still rings: no state change for it (see the
    // block above prepareRinging).
    final whileRinging = _standby;
    try {
      if (!isRestart && !whileRinging) {
        // A restart offer arrives mid-call - moving to `ringing` would be
        // wrong (we're not receiving a new incoming call, just
        // renegotiating an existing one). recovering -> connected is
        // reached the normal way, via onConnectionState once ICE
        // reconnects, not through a state change here.
        _setState(CallState.ringing);
      }
      // The caller's second try at a connection that failed: no longer
      // waiting for it.
      if (isRestart) _restartWaitTimer?.cancel();
      _event('SDP_OFFER_RECEIVED', extra: {
        'restart': isRestart, 'offer_id': offerId, 'standby': whileRinging, ...sdpDirections(sdp),
      });
      // Candidates that arrive while it is applied wait for it (_addIce).
      _applyingRemote = true;
      try {
        await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
      } finally {
        if (pcGen == _pcGen) _applyingRemote = false;
      }
      if (stale()) return;
      _remoteDescriptionSet = true;
      _remoteUfrag = sdpIceUfrag(sdp);
      if (!isRestart) await _answerWithMicrophoneSlot(pc);
      if (stale()) return;
      final answer = await pc.createAnswer(
          {'offerToReceiveAudio': true, 'offerToReceiveVideo': isVideo});
      if (stale()) return;
      final tunedAnswer = _tuneSdp(answer);
      _beginLocalDescription();
      await pc.setLocalDescription(tunedAnswer);
      if (stale()) return;
      _lastLocalAnswer = tunedAnswer; // cache for resend - see 'ready' handler in _onSignal
      if (!isRestart) _answeredOfferId = offerId;
      _event('SDP_ANSWER_CREATED', extra: {
        'restart': isRestart, 'offer_id': offerId, ...sdpDirections(tunedAnswer.sdp),
      });
      // The answer goes first: the caller can do nothing until it has it.
      // Its candidates follow it (held until now - _holdLocalIce), then the
      // caller's that came ahead of it, and the video bitrate cap - those
      // used to hold the answer back by a platform round trip each.
      _ws?.sink.add(jsonEncode({
        'type': 'answer', 'room_id': roomId, 'sdp': tunedAnswer.sdp,
        // Echo the flag back so the offerer can tell this answer apart from
        // a replayed duplicate of the original one (see _handleAnswer).
        if (isRestart) 'restart': true,
        if (!isRestart && offerId != null) 'offer_id': offerId,
      }));
      final held = _localIceBeforePeer.length;
      _descriptionSent();
      _event('SDP_ANSWER_SENT', extra: {'restart': isRestart, 'offer_id': offerId, 'count': held});
      await _flushPendingIce();
      if (stale()) return;
      // Negotiation is complete on this side, so the sender now has real
      // encodings to cap. See _applyVideoBitrateCap.
      await _applyVideoBitrateCap();
    } catch (e, st) {
      // Same fix as _makeOffer() above - see that method's comment.
      if (!stale()) {
        _holdLocalIce = false;
        debugPrint('WebRTC: _handleOffer failed: $e\n$st');
        _event('SDP_FAILED', reason: 'answer_failed', error: e, extra: {'restart': isRestart});
        if (_standby) {
          // While it rings: Accept answers the old way.
          _abandonPreconnect(reason: 'answer_failed', error: e);
        } else {
          _fail('Could not answer the call: $e', code: 'answer_failed', error: e);
        }
      }
    }
  }

  /// Callee: before its microphone is open - the phone is ringing, or the
  /// microphone is opening after Accept - an offer's audio would be
  /// answered receive-only, and the microphone could then only join through
  /// a second offer and answer. It is answered send-and-receive instead,
  /// with nothing on the sender until _attachMicrophone puts the microphone
  /// there. Voice calls; a classic answer, microphone already on, has
  /// nothing receive-only to change.
  Future<void> _answerWithMicrophoneSlot(RTCPeerConnection pc) async {
    if (isCaller || isVideo) return;
    try {
      for (final t in await pc.getTransceivers()) {
        final kind = t.receiver.track?.kind;
        if (kind != null && kind != 'audio') continue;
        if (await t.getDirection() == TransceiverDirection.RecvOnly) {
          await t.setDirection(TransceiverDirection.SendRecv);
          debugPrint('WebRTC: AUDIO_SLOT_OPENED room=$roomId (microphone joins on Accept)');
        }
      }
    } catch (e) {
      debugPrint('WebRTC: could not open the audio slot: $e');
    }
  }

  /// Callee: a new peer connection for an offer that replaces the one this
  /// phone answered (see _handleOffer). False when the call ended meanwhile.
  Future<bool> _rebuildForNewOffer() async {
    final gen = _generation;
    final config = _pcConfig;
    if (config == null) return false;
    _pcGen++;
    final old = _pc;
    _pc = null;
    _remoteDescriptionSet = false;
    _lastLocalAnswer = null;
    _answeredOfferId = null;
    _transportUp = false;
    _pcState = null;
    // Not the queued candidates: the caller's new connection may have sent
    // some ahead of this offer. They name its ICE session and are added
    // once it is applied; the old connection's never match (_flushPendingIce).
    _remoteUfrag = null;
    _applyingRemote = false;
    _holdLocalIce = false;
    _sentLocalIce.clear();
    _localIceBeforePeer.clear();
    _heldRemoteTracks.clear();
    try { await old?.close(); } catch (_) {}
    if (gen != _generation) return false;
    // With the microphone, when it is open: _newPc adds it.
    await _createPc(config);
    return gen == _generation && _pc != null;
  }

  Future<void> _handleAnswer(String sdp, {bool isRestart = false, String? offerId}) async {
    final gen = _generation;
    // Duplicate-answer guard (Section 8) - same reasoning as _handleOffer,
    // and now with the same ICE-restart exception _handleOffer has always
    // had. An answer is legitimate (not a duplicate) when it answers a
    // restart offer we are actually waiting on: either the peer echoed our
    // `restart` flag back, or we know we're mid-restart. Without this the
    // restart handshake could never complete - see _awaitingRestartAnswer.
    // An answer naming an offer is an answer to that first offer, never to
    // a restart: a resent one, arriving mid-restart, would otherwise be set
    // in its place.
    final restartAnswer = isRestart || (_awaitingRestartAnswer && offerId == null);
    if (_remoteDescriptionSet && !restartAnswer) {
      debugPrint('WebRTC: ignoring duplicate answer');
      return;
    }
    // An answer to an offer of a connection since replaced - negotiated
    // with a phone that left, say - or to no offer at all.
    if (!restartAnswer && offerId != null && offerId != _offerId) {
      debugPrint('WebRTC: ignoring an answer to an earlier offer');
      return;
    }
    final pc = _pc;
    if (pc == null) return;
    final pcGen = _pcGen;
    try {
      _event('SDP_ANSWER_RECEIVED', extra: {
        'restart': restartAnswer, 'offer_id': offerId, ...sdpDirections(sdp),
      });
      // Candidates that arrive while it is applied wait for it (_addIce).
      _applyingRemote = true;
      try {
        await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
      } finally {
        if (pcGen == _pcGen) _applyingRemote = false;
      }
      if (gen != _generation || pcGen != _pcGen) return;
      _remoteDescriptionSet = true;
      _remoteUfrag = sdpIceUfrag(sdp);
      _awaitingRestartAnswer = false;
      await _flushPendingIce();
      if (gen != _generation || pcGen != _pcGen) return;
      // Caller side: the answer completes negotiation, so this is the first
      // moment the video sender has real encodings. See
      // _applyVideoBitrateCap.
      await _applyVideoBitrateCap();
      if (_renegotiationQueued && gen == _generation) {
        _renegotiationQueued = false;
        unawaited(_renegotiate());
      }
    } catch (e, st) {
      // Same fix as _makeOffer() above - see that method's comment. Not
      // for a connection closed under it (_resetPreconnect): the call
      // carries on on its replacement.
      if (gen == _generation && pcGen == _pcGen) {
        debugPrint('WebRTC: _handleAnswer failed: $e\n$st');
        _event('SDP_FAILED', reason: 'remote_answer_failed', error: e,
            extra: {'restart': restartAnswer});
        _fail('Could not complete the call connection: $e', code: 'answer_failed', error: e);
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
    final info = CandidateInfo.parse(candidate.candidate);
    diagnostics.countReceived(info.type);
    // Named for an ICE session other than the one applied: a description
    // still on its way (a restart, a new offer) - see _holdLocalIce.
    final forAnother = _forAnotherSession(info);
    final queue = !_remoteDescriptionSet || _pc == null || _applyingRemote || forAnother;
    _event('ICE_CANDIDATE_RECEIVED', extra: {
      'candidate_type': info.type, 'protocol': info.protocol, 'queued': queue,
      if (forAnother) 'stale': true,
    });
    if (queue) {
      // Candidates can legitimately arrive before the offer/answer that
      // establishes the remote description, depending on network timing -
      // queue instead of calling addCandidate() too early, which throws.
      // Flushed by _flushPendingIce() once the remote description lands.
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

  bool _forAnotherSession(CandidateInfo info) =>
      info.ufrag != null && _remoteUfrag != null && info.ufrag != _remoteUfrag;

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
      _event('ICE_CANDIDATE_FAILED', error: e,
          extra: {'candidate_type': CandidateInfo.parse(candidate.candidate).type});
    }
  }

  Future<void> _flushPendingIce() async {
    if (_pendingIce.isEmpty) return;
    final queued = List<RTCIceCandidate>.from(_pendingIce);
    _pendingIce.clear();
    var added = 0;
    for (final c in queued) {
      if (_forAnotherSession(CandidateInfo.parse(c.candidate))) {
        // Not this description's: kept for the one it names.
        _pendingIce.add(c);
        continue;
      }
      await _addIceNow(c);
      added++;
    }
    debugPrint('WebRTC: ICE_CANDIDATES_FLUSHED room=$roomId count=$added kept=${_pendingIce.length}');
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
    _event('TURN_CREDENTIAL_REQUEST');
    final started = DateTime.now();
    TurnCredentialsResult result;
    try {
      // With this call's own token: no access token, so no renewal first.
      result = await ApiService.fetchTurnCredentials(roomId: roomId, callToken: _callToken);
    } catch (e) {
      result = TurnCredentialsResult(null, 'error: ${e.runtimeType}');
    }
    final ms = DateTime.now().difference(started).inMilliseconds;
    final creds = result.data;
    final iceServers = creds?['ice_servers'];
    if (creds == null || iceServers is! List || iceServers.isEmpty) {
      // STUN only: on carrier-grade NAT - most Kenyan mobile data - that
      // usually means no connection at all. Said, so a call that then
      // fails says why (2026-11-13: it said nothing).
      _iceConfigIsFallback = true;
      _event('TURN_CREDENTIAL_FAILURE',
          reason: creds == null ? (result.failure ?? 'unknown') : 'no_ice_servers',
          extra: {'ms': ms});
      return _fallbackIceConfig;
    }
    _iceConfigIsFallback = false;
    final expiresIn = creds['expires_in'];
    if (expiresIn is int) {
      _iceCredentialsExpireAt = DateTime.now().add(Duration(seconds: expiresIn));
    }
    final turnUrls = <String>[
      for (final s in iceServers)
        if (s is Map)
          for (final u in (s['urls'] is List ? s['urls'] as List : [s['urls']]))
            if (u is String && (u.startsWith('turn:') || u.startsWith('turns:'))) u,
    ];
    _event('TURN_CREDENTIAL_RECEIVED', extra: {
      'turn_urls': turnUrls.length,
      'udp': turnUrls.any((u) => u.contains('transport=udp')),
      'tcp': turnUrls.any((u) => u.startsWith('turn:') && u.contains('transport=tcp')),
      'tls': turnUrls.any((u) => u.startsWith('turns:')),
      'ttl_s': expiresIn is int ? expiresIn : null,
      'ms': ms,
    });
    return {
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
      ..._transportPolicy,
    };
  }

  static bool _hasTurn(Map<String, dynamic> config) {
    final servers = config['iceServers'];
    if (servers is! List) return false;
    for (final s in servers) {
      if (s is! Map) continue;
      final urls = s['urls'];
      for (final u in (urls is List ? urls : [urls])) {
        if (u is String && (u.startsWith('turn:') || u.startsWith('turns:'))) return true;
      }
    }
    return false;
  }

  Future<void> _createPc(Map<String, dynamic> iceConfig) async {
    final pc = await _newPc(iceConfig);
    if (pc != null) _pc = pc;
  }

  /// A peer connection with this phone's tracks and every handler on it,
  /// or null when the call (or this connection) was replaced meanwhile.
  Future<RTCPeerConnection?> _newPc(Map<String, dynamic> iceConfig) async {
    final gen = _generation;
    final pcGen = ++_pcGen;
    _pcConfig = iceConfig;
    _turnConfigured = _hasTurn(iceConfig);
    _iceGatheringName = 'new';
    _iceConnectionName = 'new';
    _pcStateName = 'new';
    bool stale() => gen != _generation || pcGen != _pcGen;
    // Published as _pc only once its tracks and handlers are in place: the
    // callee's socket is open while this runs (start), and an offer handled
    // against a connection with no microphone track yet would be answered
    // receive-only - a call in which the other side hears nothing.
    final pc = await _takePreparedPc() ?? await _nativePc(iceConfig);
    debugPrint('WebRTC: PEER_CONNECTION_CREATED room=$roomId');
    if (stale()) { try { await pc.close(); } catch (_) {} return null; }

    // Add local audio (+ video, for video calls) tracks. addTrack is async
    // and returns the sender - previously its Future was dropped on the
    // floor inside a forEach, so (a) the tracks weren't guaranteed to be
    // attached before createOffer ran, which on a slow device produces an
    // offer with no media in it, and (b) there was no handle on the video
    // sender to apply a send-side bitrate cap to.
    for (final t in (_local?.getTracks() ?? const <MediaStreamTrack>[])) {
      await pc.addTrack(t, _local!);
      debugPrint('WebRTC: ${t.kind == "video" ? "LOCAL_VIDEO_TRACK_ADDED" : "LOCAL_AUDIO_TRACK_ADDED"} room=$roomId');
    }
    if (stale()) { try { await pc.close(); } catch (_) {} return null; }
    // NOT capping the bitrate here. Encodings don't exist until the
    // transceiver is negotiated - see _applyVideoBitrateCap's doc comment.
    // It is applied from the two places where negotiation has just
    // completed instead (_handleOffer's answer, _handleAnswer).

    // Send ICE candidates to remote peer
    pc.onIceCandidate = (c) {
      // FORENSIC FIX: this callback fires directly from the native
      // flutter_webrtc plugin with no error handling at all - any failure
      // in jsonEncode()/the WS sink's add() (e.g. StateError if the sink
      // happens to be closed/reconnecting right at this moment) became an
      // unhandled exception escaping a native platform-channel callback,
      // a plausible contributor to the reported crash. Both operations
      // here are synchronous, so a plain try/catch is sufficient - no
      // await needed.
      if (stale()) return;
      if (c.candidate == null) return;
      try {
        final info = CandidateInfo.parse(c.candidate);
        diagnostics.countGathered(info.type);
        _roundGathered[info.type ?? 'unknown'] = (_roundGathered[info.type ?? 'unknown'] ?? 0) + 1;
        final frame = jsonEncode({
          'type': 'ice', 'room_id': roomId,
          'candidate': {
            'candidate':     c.candidate,
            'sdpMid':        c.sdpMid,
            'sdpMLineIndex': c.sdpMLineIndex,
          },
        });
        // Gathered while their phone rings (nobody to relay it to yet), or
        // before the description it belongs to has gone (_holdLocalIce).
        final hold = (isCaller && !_peerInRoom) || _holdLocalIce;
        _event('ICE_CANDIDATE_GATHERED', extra: {
          'candidate_type': info.type, 'protocol': info.protocol, 'held': hold,
        });
        if (hold) {
          _localIceBeforePeer.add(frame);
          return;
        }
        _sentLocalIce.add(frame);
        _ws?.sink.add(frame);
      } catch (e) {
        debugPrint('WebRTC: failed to send local ICE candidate: $e');
      }
    };

    // Connection state machine - the ONLY thing allowed to move CallState
    // to `connected` (Section 13/Phase 10: WS/ICE-gathering/etc. state
    // changes are diagnostic-only below, never call _setState()).
    pc.onConnectionState = (s) {
      if (stale()) return; // stale callback from a torn-down call or connection
      try {
        _pcState = s;
        _pcStateName = _stateName(s, 'RTCPeerConnectionState');
        switch (s) {
          case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
            _transportUp = true;
            if (_preconnecting) {
              // Up while their phone rings, or while this one's microphone
              // opens: put through once it is answered (_onCallerReady,
              // _startPreconnected) - not now, and nothing told the server.
              _event('WEBRTC_CONNECTED', extra: {'held': true});
              break;
            }
            _onPeerConnected();
            break;
          case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
            _transportUp = false;
            if (_preconnecting) {
              // Failed while it rang: not the call failing - nobody has
              // answered. Accept takes the old way.
              _event('WEBRTC_FAILED', reason: 'preconnect_failed', extra: _iceCounts());
              if (isCaller) {
                unawaited(_resetPreconnect(peerStillHere: false));
              } else if (_standby) {
                _abandonPreconnect(reason: 'preconnect_failed');
              } else {
                // Accepted, the microphone still opening: the call failed.
                _reportWebRtcState('failed');
                _fail('WebRTC connection failed', code: 'ice_failed');
              }
              break;
            }
            if (!_everConnected) {
              if (_canRestartBeforeConnect) {
                // The connection never came up: one more try, ICE
                // restarted with fresh relay credentials.
                _event('WEBRTC_FAILED', reason: 'ice_failed_retrying', extra: _iceCounts());
                _restartBeforeConnect('ice_failed');
                break;
              }
              if (!isCaller && !_restartWaited && _ws != null) {
                // The caller drives that second try: wait for its restart
                // offer a moment before giving up.
                _restartWaited = true;
                _event('WEBRTC_FAILED', reason: 'ice_failed_waiting_for_restart', extra: _iceCounts());
                _restartWaitTimer?.cancel();
                _restartWaitTimer = Timer(_restartWait, () {
                  if (gen != _generation || _everConnected) return;
                  if (_state == CallState.ended || _state == CallState.failed) return;
                  _reportWebRtcState('failed');
                  _fail('WebRTC connection failed', code: 'ice_failed');
                });
                break;
              }
            }
            _reportWebRtcState('failed');
            _fail('WebRTC connection failed', code: _everConnected ? 'connection_lost' : 'ice_failed');
            break;
          case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
            _transportUp = false;
            if (_state == CallState.connected) {
              // Don't fail immediately - ICE frequently self-heals from a
              // brief disconnect (Wi-Fi/cell handoff, momentary NAT
              // rebind) with no action needed. Give it a short grace
              // period; only attempt an ICE restart - and only then
              // eventually fail - if it's still unhealthy once that
              // expires.
              _reportWebRtcState('disconnected');
              _setState(CallState.recovering);
              _event('WEBRTC_DISCONNECTED', extra: {'ms': _disconnectGracePeriod.inMilliseconds});
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
    pc.onIceGatheringState = (s) {
      if (stale()) return;
      _iceGatheringName = _stateName(s, 'RTCIceGatheringState');
      if (s != RTCIceGatheringState.RTCIceGatheringStateComplete) return;
      // What this phone could offer to be reached by. No relay candidate
      // with TURN configured is the relay itself failing - wrong or
      // expired credentials, or TURN blocked on this network.
      final relays = _roundGathered['relay'] ?? 0;
      _event('ICE_GATHERING_COMPLETE', extra: {
        'host': _roundGathered['host'] ?? 0, 'srflx': _roundGathered['srflx'] ?? 0,
        'relay': relays, 'prflx': _roundGathered['prflx'] ?? 0, 'turn': _turnConfigured,
      });
      if (_turnConfigured && relays == 0) _event('TURN_NO_RELAY_CANDIDATES');
    };
    pc.onIceConnectionState = (s) {
      if (stale()) return;
      _iceConnectionName = _stateName(s, 'RTCIceConnectionState');
      final name = switch (s) {
        RTCIceConnectionState.RTCIceConnectionStateChecking => 'ICE_CONNECTION_CHECKING',
        RTCIceConnectionState.RTCIceConnectionStateConnected => 'ICE_CONNECTION_CONNECTED',
        RTCIceConnectionState.RTCIceConnectionStateCompleted => 'ICE_CONNECTION_COMPLETED',
        RTCIceConnectionState.RTCIceConnectionStateFailed => 'ICE_CONNECTION_FAILED',
        RTCIceConnectionState.RTCIceConnectionStateDisconnected => 'ICE_CONNECTION_DISCONNECTED',
        RTCIceConnectionState.RTCIceConnectionStateClosed => 'ICE_CONNECTION_CLOSED',
        _ => null,
      };
      if (name == null) return;
      _event(name, extra: name == 'ICE_CONNECTION_FAILED' ? _iceCounts() : const {});
    };
    pc.onSignalingState = (s) {
      if (stale()) return;
      debugPrint('WebRTC: signaling state = $s');
    };

    // Remote track received. For video calls this stream carries both the
    // audio and video tracks together, so attaching it to the renderer here
    // is correct regardless of which specific track fired the event.
    pc.onTrack = (event) {
      if (stale()) return;
      try {
        final isVideoTrack = event.track.kind == 'video';
        debugPrint('WebRTC: ${isVideoTrack ? "REMOTE_VIDEO_TRACK_RECEIVED" : "REMOTE_AUDIO_TRACK_RECEIVED"} room=$roomId');
        if (_holdRemote) {
          // The caller's audio, arriving while this phone still rings:
          // silent until Accept (_releaseRemoteMedia).
          event.track.enabled = false;
          _heldRemoteTracks.add(event.track);
          return;
        }
        if (event.streams.isEmpty) return;
        // Any remote media at all means the call is up.
        onRemoteStreamConnected?.call();

        if (!isVideoTrack) return;
        unawaited(_showRemoteVideo(event, gen));
      } catch (e, st) {
        // Same reasoning as onConnectionState above - never let a native
        // callback propagate an uncaught exception.
        debugPrint('WebRTC: onTrack handler failed: $e\n$st');
      }
    };

    return pc;
  }

  /// The connection is up and the call answered: the call is connected.
  /// Once per connection - a callee put through as its microphone opened
  /// would otherwise start the clock, the sampling and the diagnostics a
  /// second time when the connection's own callback caught up.
  void _onPeerConnected() {
    if (_state == CallState.connected) return;
    _disconnectGraceTimer?.cancel();
    _disconnectGraceTimer = null;
    _restartWaitTimer?.cancel();
    final recovered = _everConnected;
    final restarts = _iceRestartAttempts;
    _iceRestartAttempts = 0; // reset - this is either the first connect or a successful recovery
    _setState(CallState.connected);
    if (_state != CallState.connected) return; // refused (the call is over)
    _everConnected = true;
    // Connected means the peer connection says so - never the signalling
    // having crossed (2026-11-13: SDP and ICE were relayed, and nothing
    // ever connected).
    _event('WEBRTC_CONNECTED', extra: {
      'elapsed_ms': recovered || _connectingStartedAt == null
          ? null
          : DateTime.now().difference(_connectingStartedAt!).inMilliseconds,
      'recovered': recovered,
      'ice_restarts': recovered ? restarts : _initialRestarts,
      'reconnects': _reconnectAttempts,
      'turn': _turnConfigured,
    });
    _startTimer();
    _startQualitySampling();
    onRemoteStreamConnected?.call();
    _reportDiagnosticsOnceConnected();
    _reportWebRtcState('connected');
  }

  /// The other side's picture. On a voice call this is them having turned
  /// their camera on (a renegotiation): this side becomes a video call too.
  /// It used to be dropped - a voice call had no renderer to show it on.
  Future<void> _showRemoteVideo(RTCTrackEvent event, int gen) async {
    try {
      if (!isVideo) await _becomeVideo();
      if (gen != _generation) return;
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
      debugPrint('WebRTC: remote video failed: $e\n$st');
    }
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

  static const Map<String, dynamic> _videoConstraints = {
    'facingMode': 'user',
    'width':  {'ideal': 640},
    'height': {'ideal': 480},
    // Capping capture frame rate is the cheapest bandwidth/CPU saving
    // available for video: 24fps is indistinguishable from 30 for a talking
    // head, and a budget phone's encoder has 20% less work to do. `ideal`
    // only - a hard `max` can make some Android camera stacks refuse to
    // open the device at all.
    'frameRate': {'ideal': 24},
  };

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

    _local = await _openMedia({
      'audio': {
        'echoCancellation': true,
        'noiseSuppression': true,
        'autoGainControl':  true,
      },
      'video': wantVideo ? _videoConstraints : false,
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
      // report.values comes back as Map<dynamic, dynamic> from
      // flutter_webrtc - converted, since every key is a stats field name.
      Map<String, dynamic>? byId(Object? id) {
        if (id == null) return null;
        for (final report in stats) {
          if (report.id == id) return Map<String, dynamic>.from(report.values);
        }
        return null;
      }

      // The transport names the pair in use; older stacks only mark it
      // nominated (or "selected") and succeeded.
      Map<String, dynamic>? selectedPair;
      for (final report in stats) {
        if (report.type == 'transport') {
          selectedPair = byId(report.values['selectedCandidatePairId']);
          if (selectedPair != null) break;
        }
      }
      if (selectedPair == null) {
        for (final report in stats) {
          final v = report.values;
          if (report.type == 'candidate-pair' &&
              v['state'] == 'succeeded' &&
              (v['nominated'] == true || v['selected'] == true)) {
            selectedPair = Map<String, dynamic>.from(v);
            break;
          }
        }
      }
      final local = byId(selectedPair?['localCandidateId']);
      final remote = byId(selectedPair?['remoteCandidateId']);
      final localType = local?['candidateType'] as String?;
      final remoteType = remote?['candidateType'] as String?;
      if (localType == 'relay') {
        path = 'turn';
      } else if (localType == 'srflx' || localType == 'prflx') {
        path = 'stun';
      } else if (localType == 'host') {
        path = 'direct';
      }
      // host | srflx | relay, as the logs name it: relayed if either side is.
      _path = (localType == 'relay' || remoteType == 'relay')
          ? 'relay'
          : (localType == 'srflx' || localType == 'prflx' ||
                  remoteType == 'srflx' || remoteType == 'prflx')
              ? 'srflx'
              : (localType == 'host' ? 'host' : '-');
      final rtt = selectedPair?['currentRoundTripTime'];
      _event('ICE_CANDIDATE_PAIR_SELECTED', extra: {
        'local_type': localType, 'remote_type': remoteType,
        'local_protocol': local?['protocol'], 'remote_protocol': remote?['protocol'],
        'relay_protocol': local?['relayProtocol'],
        'rtt_ms': rtt is num ? (rtt * 1000).round() : null,
      });
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
    _restartWaitTimer?.cancel();
    final sub = _wsSub;
    _wsSub = null;
    unawaited(sub?.cancel());
    _wsState = 'closed';
    // What never reached Render over the socket - it was down, or the call
    // ended as it happened - goes in one post, now, with the token the
    // call has (the server takes it a while after it expires).
    final unsent = diagnostics.takeUnsent();
    if (unsent.isNotEmpty) unawaited(ApiService.postCallEvents(roomId, _callToken, unsent));
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
    try { await (await _takePreparedPc())?.close(); } catch (_) {}
    try {
      _local?.getTracks().forEach((t) => t.stop());
      await _local?.dispose();
    } catch (_) {}
    final camera = _camera;
    _camera = null;
    if (camera != null) await _disposeStream(camera);
    try { await _ws?.sink.close(); } catch (_) {}
    // Hand the audio route AND the audio mode back to the platform, so the
    // next media playback (a voice note, the next call's ringtone) isn't
    // stuck on the voice-call stream for the rest of the session. The
    // speaker flag alone never did this - see _setAudioMode.
    try { await Helper.setSpeakerphoneOn(false); } catch (_) {}
    await _setAudioMode(inCall: false);
    _pc = null; _local = null; _ws = null;
    _pcGen++;
    _iceCredentialsExpireAt = null;
    _iceConfigFuture = null;
    _offerFuture = null;
    _offerBeforePc = null;
    _offerIdBeforePc = null;
    _peerInRoom = false;
    // Answering while it rings (see prepareRinging).
    _standby = false;
    _holdRemote = false;
    _heldRemoteTracks.clear();
    _attachingMedia = false;
    _standbyPeer = null;
    _mediaHeld = false;
    _transportUp = false;
    _pcState = null;
    _localIceBeforePeer.clear();
    _sentLocalIce.clear();
    _holdLocalIce = false;
    _applyingRemote = false;
    _remoteUfrag = null;
    _renegotiationQueued = false;
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
    // offer goes out (_deliverOffer): the callee has answered and joined, and
    // from there 30s really is a stuck negotiation. The no-answer window is
    // the call screen's (and the server's). Since 2026-11-09 an offer can go
    // to a phone still ringing: the clock starts at `ready`, when the
    // callee has joined (_onCallerReady), not at the offer. The callee's
    // `connecting` is armed by start() once its microphone is open.
    if (s == CallState.ringing || (s == CallState.calling && _calleeJoined)) {
      _armConnectTimeout();
    } else {
      _disarmConnectTimeout();
    }
    onStateChange?.call(s);
  }

  void _armConnectTimeout([Duration? after]) {
    _connectTimeoutTimer?.cancel();
    final gen = _generation;
    _connectTimeoutTimer = Timer(after ?? _connectTimeout, () {
      if (gen == _generation) _onConnectTimeout();
    });
  }

  /// The connection did not come up in time. Distinct from the VoIP
  /// screen's own "nobody answered" ring timeout: this runs only once the
  /// call has been answered - and each side gives up on its own terms:
  ///
  ///  * callee with no offer at all: the caller is not in the room - it
  ///    gave up before it could join, or never got the room (2026-11-13).
  ///    Nothing is coming; it ends now, saying so.
  ///  * callee with an offer: the caller drives the connection's second
  ///    try (an ICE restart), so the callee waits that much longer, once.
  ///  * caller: one ICE restart with fresh relay credentials, then it ends.
  void _onConnectTimeout() {
    final waiting = _state == CallState.calling || _state == CallState.ringing ||
        (_state == CallState.connecting && !isCaller);
    if (!waiting) return;
    if (!isCaller) {
      if (!_remoteDescriptionSet) {
        _event('CALL_TIMEOUT', reason: 'no_offer');
        _fail("The caller couldn't connect. Try calling them back.", code: 'no_offer');
        return;
      }
      if (!_establishmentExtended) {
        _establishmentExtended = true;
        _armConnectTimeout(_calleeExtraWait);
        return;
      }
      _event('CALL_TIMEOUT', reason: 'ice_timeout', extra: _iceCounts());
      _fail("The call couldn't connect. Check your connection and try again.", code: 'ice_timeout');
      return;
    }
    if (!_remoteDescriptionSet) {
      _event('CALL_TIMEOUT', reason: 'no_answer_sdp');
      _fail("Their phone couldn't join the call. Try again.", code: 'no_answer_sdp');
      return;
    }
    if (_canRestartBeforeConnect) {
      _restartBeforeConnect('connect_timeout');
      return;
    }
    _event('CALL_TIMEOUT', reason: 'ice_timeout', extra: _iceCounts());
    _fail("The call couldn't connect. Check your connection and try again.", code: 'ice_timeout');
  }

  void _disarmConnectTimeout() {
    _connectTimeoutTimer?.cancel();
    _connectTimeoutTimer = null;
  }

  // The failures that are the connection's, as WEBRTC_FAILED.
  static const _connectionFailures = {
    'ice_failed', 'ice_timeout', 'connection_lost', 'restart_failed',
  };

  /// The call failed: the other phone is told (it used to be left on
  /// "Connecting…" until its own timeout), the logs are told why, and the
  /// screen gets a sentence a person can act on. [code] is the reason in
  /// one word, for the recorded outcome and the logs.
  void _fail(String msg, {String code = 'failed', Object? error}) {
    if (_state == CallState.ended || _state == CallState.failed) return;
    _failureReason ??= code;
    final reported = error ?? (msg == code ? null : msg);
    if (_connectionFailures.contains(code)) {
      _event('WEBRTC_FAILED', reason: code, error: reported, extra: _iceCounts(), terminal: true);
    }
    _event('CALL_ENDED', reason: code, error: reported, terminal: true, extra: {
      'connected': _everConnected, 'outcome': 'failed',
      'ice_restarts': _initialRestarts + _iceRestartAttempts, 'reconnects': _reconnectAttempts,
    });
    if (!_standby) {
      try {
        _ws?.sink.add(jsonEncode({
          'type': 'hangup', 'room_id': roomId, 'reason': 'failed', 'detail': code,
        }));
      } catch (_) {}
    }
    _cleanup();
    _setState(CallState.failed);
    // [msg] can carry the exception that ended the call (a socket
    // error naming the server); the screen gets the plain version.
    onError?.call(sanitizeErrorText(msg,
        fallback: "The call couldn't connect. Please try again."));
  }
}
