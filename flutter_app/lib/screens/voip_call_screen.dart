// BROKA - Polished In-App VoIP Call Screen
// Multi-ring ripple animation · call quality badge · per-state gradients
// Incoming call full-screen takeover · smooth state transitions
// Supports both audio and video calls (see WebRtcService.callType).

import 'dart:async';
import 'dart:math' as math;
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../main.dart';
import '../services/webrtc_service.dart';
import '../services/api_service.dart';
import '../services/ringtone_service.dart';
import '../services/notification_service.dart';
import '../services/call_foreground_service.dart';
import '../services/callkit_service.dart';

class VoipCallScreen extends StatefulWidget {
  const VoipCallScreen({super.key});
  @override
  State<VoipCallScreen> createState() => _VoipCallScreenState();
}

class _VoipCallScreenState extends State<VoipCallScreen>
    with TickerProviderStateMixin {

  late WebRtcService _svc;
  String _peerName    = '';
  String? _peerPhoto;          // inline base64; falls back to initials
  // Peer presence at dial time. null == unknown (older call sites).
  bool? _peerOnline;
  String _listingName = '';
  bool   _isCaller    = true;
  bool   _argsLoaded  = false;
  String _callType    = 'audio'; // 'audio' | 'video'

  CallState _callState = CallState.connecting;
  Duration  _duration  = Duration.zero;
  bool      _muted     = false;
  bool      _speaker   = false;
  bool      _videoOn   = true;
  String?   _errorMsg;
  bool      _accepted  = false;   // callee tapped Accept
  bool      _endingCall = false;  // guards Decline/Hangup against a rapid double-tap
  String    _listingId  = '';
  String    _buyerId    = '';
  String    _callerRole = 'buyer';
  bool      _everConnected = false;
  bool      _resultLogged  = false;
  bool      _declinedByMe  = false; // callee explicitly tapped Decline
  // Real, measured quality (packet loss + jitter) from WebRtcService -
  // replaces the old badge that was derived purely from elapsed seconds.
  CallQuality _quality = CallQuality.unknown;

  // Video-call-only render state.
  bool _localMediaReady   = false; // localRenderer has a live camera feed
  bool _remoteVideoActive = false; // remoteRenderer has a live peer feed

  // ── Animations ────────────────────────────────────────────────────────────
  late AnimationController _ringCtrl;     // ripple rings
  late AnimationController _fadeCtrl;     // state fade
  late AnimationController _connectedCtrl;// bounce in when connected

  bool get _isVideo => _callType == 'video';

  // Full-bleed remote video only once it's actually flowing, and only while
  // the call is genuinely active - on end/failure we fall back to the
  // familiar gradient + avatar treatment rather than a frozen last frame.
  bool get _showRemoteVideo => _isVideo && _remoteVideoActive &&
      _callState != CallState.ended && _callState != CallState.failed;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);

    _ringCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1800))
      ..repeat();
    _fadeCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 400))
      ..forward();
    _connectedCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 600));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_argsLoaded) return;
    final args = ModalRoute.of(context)?.settings.arguments as Map?;
    if (args == null) return;
    _argsLoaded  = true;
    final roomId = args['roomId']      as String? ?? '';
    final userId = args['userId']      as String? ?? '';
    final callToken = args['callToken'] as String? ?? '';
    _peerName    = args['peerName']    as String? ?? 'User';
    _peerPhoto   = args['peerPhoto']   as String?;
    _peerOnline  = args['peerOnline']  as bool?;
    _listingName = args['listingName'] as String? ?? '';
    _isCaller    = args['isCaller']    as bool?   ?? true;
    _listingId   = args['listingId']   as String? ?? '';
    _buyerId     = args['buyerId']     as String? ?? '';
    _callerRole  = args['callerRole']  as String? ?? 'buyer';
    _callType    = args['callType']    as String? ?? 'audio';
    final autoAccept = args['autoAccept'] as bool? ?? false;

    // Whichever path got us here, the ringing notification (if any) has
    // done its job - take it down before anything else so it can't keep
    // ringing behind the call screen.
    NotificationService.instance.cancelIncomingCall(roomId);

    _svc = WebRtcService(
      roomId: roomId, isCaller: _isCaller, userId: userId,
      callToken: callToken, callType: _callType,
    );

    _svc.onStateChange = (s) {
      // Whatever just happened, any still-ringing tone is no longer needed -
      // this is a defensive catch-all on top of the explicit stops below.
      RingtoneService.instance.stop();
      if (!mounted) return;
      setState(() => _callState = s);
      if (s == CallState.connected) {
        _everConnected = true;
        CallKitService.instance.reportConnected(_svc.roomId);
        HapticFeedback.mediumImpact();
        _ringCtrl.stop();
        _connectedCtrl.forward(from: 0);
      }
      if (s == CallState.ended || s == CallState.failed) {
        _logCallResultOnce();
        CallForegroundService.stop();
        // Take the call out of iOS's native UI - otherwise the system keeps
        // showing an active call the user can't dismiss, with the audio
        // session still open.
        CallKitService.instance.endCall(_svc.roomId);
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) Navigator.pop(context);
        });
      }
    };
    _svc.onDurationTick = (d) {
      if (mounted) setState(() => _duration = d);
    };
    _svc.onError = (msg) {
      if (mounted) setState(() => _errorMsg = msg);
    };
    _svc.onLocalMediaReady = () {
      if (mounted) setState(() => _localMediaReady = true);
    };
    _svc.onRemoteStreamConnected = () {
      // Remote media of SOME kind is flowing. Deliberately does NOT flip
      // the video surface on - see onRemoteVideoChanged below.
      if (mounted && !_everConnected) setState(() {});
    };
    _svc.onRemoteVideoChanged = (active) {
      // Fires only when a remote VIDEO track is actually decoding frames
      // (or has ended). Gating the full-bleed RTCVideoView on this is what
      // stops the call from showing a black rectangle while waiting for -
      // or permanently missing - the far side's picture.
      if (mounted) setState(() => _remoteVideoActive = active);
    };
    _svc.onDiagnostics = (d) {
      // Local-only, for debugging/support purposes - nothing here is sent
      // to the backend (Phase 15). Kept lightweight: a single summary line
      // per call rather than continuous telemetry.
      debugPrint('WebRTC: CALL_DIAGNOSTICS room=$roomId $d');
    };
    _svc.onQualityChange = (q) {
      if (mounted) setState(() => _quality = q);
    };
    // The user can end or mute from iOS's native call UI (lock screen,
    // Dynamic Island) without ever touching BROKA's own controls. Without
    // these the native UI would change while the peer connection carried
    // on regardless - mic still live.
    CallKitService.instance.onEndedByNative = (endedRoomId) {
      if (endedRoomId != _svc.roomId) return;
      if (_endingCall) return;
      _endingCall = true;
      _svc.hangup();
    };
    CallKitService.instance.onMuteChanged = (mutedRoomId, muted) {
      if (mutedRoomId != _svc.roomId) return;
      if (_muted == muted) return;
      _svc.toggleMute();
      if (mounted) setState(() => _muted = muted);
    };

    if (_isCaller) {
      // Caller starts immediately - also guards the call against dropping
      // if the screen locks/backgrounds mid-call (see CallForegroundService).
      CallForegroundService.start(peerName: _peerName, isVideo: _isVideo);
      // iOS equivalent: registering with CallKit is what grants the call
      // audio session and keeps the app alive when backgrounded/locked.
      CallKitService.instance.reportOutgoingCall(
          roomId: roomId, peerName: _peerName, isVideo: _isVideo);
      _svc.start();
    } else if (autoAccept) {
      // The user already answered (notification tap, or Answer in the
      // in-chat incoming-call dialog) - don't make them decide again.
      _accepted = true;
      RingtoneService.instance.stop();
      CallForegroundService.start(peerName: _peerName, isVideo: _isVideo);
      CallKitService.instance.reportOutgoingCall(
          roomId: roomId, peerName: _peerName, isVideo: _isVideo);
      _svc.start();
    } else {
      // Callee: ring until Accept/Decline (or a safety timeout) - see
      // RingtoneService for why this is centralised rather than duplicated.
      RingtoneService.instance.play(
        autoStopAfter: const Duration(seconds: 45),
        onTimeout: () {
          if (!mounted) return;
          if (!_accepted && !_endingCall) {
            _endingCall = true;
            _svc.hangup(); // treated as a missed call
          }
        },
      );
    }
  }

  /// Logs the call's outcome once the call truly ends. "completed" if the
  /// peers ever connected (regardless of who hung up first); otherwise
  /// "declined" if the callee explicitly tapped Decline before connecting;
  /// otherwise "cancelled" if I'm the caller (I'm the one ending it before
  /// any answer - not the same as the callee failing to respond); otherwise
  /// "missed" (I'm the callee and the ring simply ran out with no action
  /// from me).
  void _logCallResultOnce() {
    if (_resultLogged) return;
    if (_listingId.isEmpty || _buyerId.isEmpty) return;
    _resultLogged = true;
    final outcome = _everConnected
        ? 'completed'
        : (_declinedByMe
            ? 'declined'
            : (_isCaller ? 'cancelled' : 'missed'));
    // Fire-and-forget: don't block call teardown/navigation on this.
    ApiService.logCallResult(
      roomId:    _svc.roomId,
      listingId: _listingId,
      buyerId:   _buyerId,
      outcome:   outcome,
      callerRole: _callerRole,
      durationSecs: _everConnected ? _duration.inSeconds : null,
      callType: _callType,
    );
  }

  @override
  void dispose() {
    RingtoneService.instance.stop();
    CallForegroundService.stop();
    CallKitService.instance.onEndedByNative = null;
    CallKitService.instance.onMuteChanged = null;
    CallKitService.instance.endCall(_svc.roomId);
    _logCallResultOnce();
    _ringCtrl.dispose();
    _fadeCtrl.dispose();
    _connectedCtrl.dispose();
    unawaited(_svc.dispose());
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String get _durationLabel {
    final m = _duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = _duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String get _initials => _peerName.trim().split(' ')
      .map((w) => w.isEmpty ? '' : w[0].toUpperCase()).take(2).join();

  /// Avatar body: failure icon > profile photo > initials.
  ///
  /// Initials are a placeholder for a missing photo, not a design choice -
  /// on a call screen the one thing the user wants confirmed is *who* they
  /// are talking to, and "XB" confirms it far less well than a face does.
  /// Every caller of this screen now passes `peerPhoto` where the backend
  /// has one (it is already on the user payload the chat header reads for
  /// its own avatar), so the initials path is reached only for users who
  /// genuinely have no picture set.
  ///
  /// errorBuilder matters more than usual here: this image loads over the
  /// network at the exact moment the radio is busy establishing a call, so
  /// a slow or failed fetch is normal rather than exceptional and must
  /// degrade to the initials instead of an exception box.
  Widget _buildAvatarContent() {
    if (_callState == CallState.failed) {
      return const Center(
        child: Icon(Icons.call_end_rounded, color: Colors.redAccent, size: 36),
      );
    }
    final photo = _peerPhoto;
    if (photo != null && photo.isNotEmpty) {
      // base64, NOT a URL.
      //
      // This shipped as Image.network and therefore never once displayed a
      // face - it failed on every call and fell silently through
      // errorBuilder to the initials, which is exactly what it looked like
      // from outside: "you said you'd replace XB with the selfie and it's
      // still XB".
      //
      // profile_photo is an inline base64 payload everywhere in this
      // codebase - profile_screen, user_profile_screen, home_screen,
      // trader_list_screen and negotiate_screen's own chat avatars all
      // decode it with base64Decode. Image.network was simply the wrong
      // widget, and its errorBuilder turned the mistake into a silent
      // no-op instead of a visible failure.
      try {
        return Image.memory(
          base64Decode(photo),
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => _initialsAvatar(),
        );
      } catch (_) {
        // Malformed base64 - decode throws rather than routing through
        // errorBuilder, so it needs catching here or it takes the screen
        // down mid-call.
        return _initialsAvatar();
      }
    }
    return _initialsAvatar();
  }

  Widget _initialsAvatar() => Center(
        child: Text(
          _initials,
          style: TextStyle(
            color: _stateColor,
            fontSize: 32,
            fontWeight: FontWeight.w900,
          ),
        ),
      );

  Color get _stateColor {
    switch (_callState) {
      case CallState.connected:  return BrokaColors.neonGreen;
      case CallState.recovering: return BrokaColors.gold;
      case CallState.failed:     return Colors.redAccent;
      case CallState.ended:      return BrokaColors.textLow;
      // Both "the far end has been alerted" states share one colour, so the
      // avatar ring visibly changes the moment the call actually reaches
      // them - gold = still our side, blue = their phone is ringing.
      case CallState.ringing:    return BrokaColors.neonBlue;
      // Gold, not blue, when we have no reason to believe it reached them:
      // the ring colour is the signal that the far end was alerted.
      case CallState.calling:
        return _peerOnline == false ? BrokaColors.gold : BrokaColors.neonBlue;
      default:                   return BrokaColors.gold;
    }
  }

  /// Three distinct pre-connection states, not one word for all of them.
  ///
  /// Previously the caller saw "Calling…" from the moment the screen opened
  /// until the callee picked up, which covered two genuinely different
  /// situations: we are still setting the call up on our side, and their
  /// phone is physically ringing. When a call failed to go through, the
  /// caller had no way to tell whether it had ever reached the other
  /// person - the screen said the same thing either way.
  ///
  /// The service already distinguishes them (webrtc_service.dart):
  ///   connecting - signalling/ICE up, offer not yet sent
  ///   calling    - offer sent, waiting for an answer == their phone rings
  ///   ringing    - (callee side) offer received, waiting on the user
  ///
  /// So the labels now follow the state machine rather than flattening it,
  /// and _stateColor moves with them: gold while we're still working,
  /// blue once the other end is actually alerted.
  String get _stateLabel {
    if (_callState == CallState.connected) return _durationLabel;
    // Callee, either state: this is an inbound call awaiting their decision.
    if (!_isCaller && !_accepted &&
        (_callState == CallState.ringing ||
         _callState == CallState.connecting)) {
      return _isVideo ? 'Incoming video call' : 'Incoming call';
    }
    switch (_callState) {
      case CallState.connecting:  return 'Connecting…';
      case CallState.calling:
        // Only claim their phone is ringing if we have reason to think it
        // is. `calling` means our offer is out - it does NOT mean anyone
        // received it. When presence says the peer is offline, the offer is
        // sitting in a room nobody is joined to, and telling the caller
        // "Ringing… / Their phone is ringing" is a straightforward lie that
        // keeps them holding the phone to their ear for 45 seconds.
        //
        // Unknown presence (null, from an older call site) keeps the
        // optimistic label - no worse than before, and never asserted on
        // evidence we do not have.
        return _peerOnline == false ? 'Trying to reach them…' : 'Ringing…';
      case CallState.ringing:     return 'Connecting…';
      case CallState.recovering:  return 'Reconnecting…';
      case CallState.ended:       return 'Call ended';
      case CallState.failed:      return _errorMsg ?? 'Call failed';
      default:                    return '';
    }
  }

  /// Sub-label under the state. Only shown pre-connection, and only when it
  /// adds something the main label doesn't: the caller's "Ringing…" earns
  /// "Their phone is ringing" because the whole point of splitting the two
  /// states is telling the user the call has left the building.
  String? get _stateDetail {
    if (_callState == CallState.connecting && _isCaller) {
      return 'Setting up the call';
    }
    if (_callState == CallState.calling && _isCaller) {
      return _peerOnline == false
          ? "They were last seen offline - they may not pick up"
          : 'Their phone is ringing';
    }
    return null;
  }

  bool get _isRinging => _callState == CallState.calling ||
      _callState == CallState.ringing ||
      _callState == CallState.connecting;

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Background layer: full-bleed remote video once it's flowing,
          // otherwise the existing state-tinted gradient.
          if (_showRemoteVideo)
            RTCVideoView(
              _svc.remoteRenderer,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            )
          else
            AnimatedContainer(
              duration: const Duration(milliseconds: 600),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    _stateColor.withOpacity(0.10),
                    BrokaColors.bg,
                    BrokaColors.bg,
                    BrokaColors.bg,
                  ],
                ),
              ),
            ),

          // Scrims so the top bar / controls stay legible over arbitrary
          // video content behind them.
          if (_showRemoteVideo) ...[
            Positioned(
              top: 0, left: 0, right: 0, height: 170,
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter, end: Alignment.bottomCenter,
                      colors: [Colors.black.withOpacity(0.55), Colors.transparent],
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              bottom: 0, left: 0, right: 0, height: 230,
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter, end: Alignment.topCenter,
                      colors: [Colors.black.withOpacity(0.6), Colors.transparent],
                    ),
                  ),
                ),
              ),
            ),
          ],

          SafeArea(
            child: Column(children: [
              _buildTopBar(),
              const Spacer(flex: 2),
              if (!_showRemoteVideo) _buildRippleAvatar(),
              const SizedBox(height: 22),
              _buildPeerInfo(),
              const SizedBox(height: 20),
              _buildStateRow(),
              const Spacer(flex: 3),
              _buildControls(),
              const SizedBox(height: 48),
            ]),
          ),

          // Local camera PIP - visible as soon as our own camera is ready,
          // for the whole call (ringing through connected).
          if (_isVideo && _localMediaReady) _buildLocalPreview(),
        ],
      ),
    );
  }

  // ── Local camera preview (PIP) ───────────────────────────────────────────

  Widget _buildLocalPreview() => Positioned(
    top: 96, right: 16,
    child: SafeArea(
      bottom: false,
      child: GestureDetector(
        onTap: () => _svc.switchCamera(),
        child: Container(
          width: 96, height: 132,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: BrokaColors.bgCard,
            border: Border.all(color: Colors.white.withOpacity(0.25)),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.45),
                  blurRadius: 14, offset: const Offset(0, 4)),
            ],
          ),
          child: (_videoOn && !_svc.cameraUnavailable)
              ? RTCVideoView(
                  _svc.localRenderer,
                  mirror: true,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                )
              : const Center(
                  child: Icon(Icons.videocam_off_rounded,
                      color: BrokaColors.textLow, size: 22),
                ),
        ),
      ),
    ),
  );

  // ── Top bar ───────────────────────────────────────────────────────────────

  Widget _buildTopBar() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
    child: Row(children: [
      // Secure badge
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: BrokaColors.bgCard,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: BrokaColors.border),
        ),
        child: const Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.lock_outline_rounded,
              size: 10, color: BrokaColors.neonGreen),
          SizedBox(width: 5),
          Text('END-TO-END ENCRYPTED',
              style: TextStyle(color: BrokaColors.neonGreen,
                  fontSize: 8, fontWeight: FontWeight.w800,
                  letterSpacing: 1.1)),
        ]),
      ),
      const Spacer(),
      // Live / quality badge
      if (_callState == CallState.connected)
        _QualityBadge(quality: _quality),
    ]),
  );

  // ── Ripple avatar ─────────────────────────────────────────────────────────

  Widget _buildRippleAvatar() {
    return AnimatedBuilder(
      animation: Listenable.merge([_ringCtrl, _connectedCtrl]),
      builder: (_, __) {
        return SizedBox(
          width: 180, height: 180,
          child: Stack(alignment: Alignment.center, children: [
            // 3 expanding ripple rings (only while not connected)
            if (_isRinging) ...[
              for (int i = 0; i < 3; i++)
                _RippleRing(
                  progress: (_ringCtrl.value + i / 3) % 1.0,
                  color: _stateColor,
                  maxRadius: 88,
                ),
            ],
            // Static outer ring (connected state)
            if (_callState == CallState.connected)
              Container(
                width: 150, height: 150,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: BrokaColors.neonGreen.withOpacity(0.2), width: 2),
                ),
              ),
            // Avatar bounce-in on connect
            ScaleTransition(
              scale: CurvedAnimation(
                parent: _callState == CallState.connected
                    ? _connectedCtrl : kAlwaysCompleteAnimation,
                curve: Curves.elasticOut,
              ),
              child: Container(
                width: 100, height: 100,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [
                      _stateColor.withOpacity(0.35),
                      _stateColor.withOpacity(0.12),
                    ],
                    begin: Alignment.topLeft, end: Alignment.bottomRight,
                  ),
                  border: Border.all(
                      color: _stateColor.withOpacity(0.7), width: 2),
                  boxShadow: [BoxShadow(
                      color: _stateColor.withOpacity(0.25),
                      blurRadius: 24, spreadRadius: 6)],
                ),
                // Real face when we have one, initials only as a fallback.
                // ClipOval + the 100x100 box means the photo fills the same
                // circle the initials used, inside the existing state-tinted
                // ring - so the ring still carries call state and the photo
                // carries identity.
                child: ClipOval(
                  child: SizedBox.expand(
                    child: _buildAvatarContent(),
                  ),
                ),
              ),
            ),
          ]),
        );
      },
    );
  }

  // ── Peer info ─────────────────────────────────────────────────────────────

  Widget _buildPeerInfo() => Column(children: [
    Text(_peerName,
        style: const TextStyle(color: BrokaColors.textHigh,
            fontSize: 26, fontWeight: FontWeight.w800)),
    if (_listingName.isNotEmpty) ...[
      const SizedBox(height: 6),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        decoration: BoxDecoration(
          color: BrokaColors.bgCard,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: BrokaColors.border),
        ),
        child: Text(_listingName,
            style: const TextStyle(color: BrokaColors.textMid, fontSize: 11),
            maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
    ],
  ]);

  // ── State label row ───────────────────────────────────────────────────────

  Widget _buildStateRow() {
    final isConnected = _callState == CallState.connected;
    final detail = _stateDetail;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      AnimatedDefaultTextStyle(
        duration: const Duration(milliseconds: 300),
        style: TextStyle(
          color: _callState == CallState.failed
              ? Colors.redAccent : _stateColor,
          fontSize:     isConnected ? 22 : 14,
          fontWeight:   isConnected ? FontWeight.w900 : FontWeight.w500,
          letterSpacing: isConnected ? 3.0 : 0.5,
          fontFamily:   'monospace',
        ),
        child: Text(_stateLabel, textAlign: TextAlign.center),
      ),
      // Only present pre-connection, and animated so the jump from
      // "Setting up the call" to "Their phone is ringing" reads as
      // progress rather than a flicker.
      AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        child: detail == null
            ? const SizedBox(height: 0, width: 0)
            : Padding(
                key: ValueKey(detail),
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  detail,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: BrokaColors.textLow,
                    fontSize: 11,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
      ),
    ]);
  }

  // ── Controls ──────────────────────────────────────────────────────────────

  Widget _buildControls() {
    if (_callState == CallState.ended || _callState == CallState.failed) {
      return _CallBtn(
        icon:  Icons.call_end_rounded,
        color: Colors.redAccent,
        label: _callState == CallState.ended ? 'Call Ended' : 'Call Failed',
        onTap: () => Navigator.pop(context),
        large: true,
      );
    }

    // Incoming call: full-screen style accept / decline
    if (!_isCaller && !_accepted &&
        (_callState == CallState.ringing ||
         _callState == CallState.connecting)) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 48),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(children: [
              _CallBtn(
                icon:  Icons.call_end_rounded,
                color: Colors.redAccent,
                label: 'Decline',
                onTap: () {
                  if (_endingCall) return;
                  _endingCall = true;
                  RingtoneService.instance.stop();
                  _declinedByMe = true;
                  _svc.hangup();
                },
                large: true,
              ),
            ]),
            // Accept - green with animated ring
            AnimatedBuilder(
              animation: _ringCtrl,
              builder: (_, child) => Stack(
                alignment: Alignment.center,
                children: [
                  Opacity(
                    opacity: (1.0 - _ringCtrl.value).clamp(0.0, 0.4),
                    child: Container(
                      width: 90 + _ringCtrl.value * 20,
                      height: 90 + _ringCtrl.value * 20,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: BrokaColors.neonGreen, width: 1.5),
                      ),
                    ),
                  ),
                  child!,
                ],
              ),
              child: _CallBtn(
                icon:  _isVideo ? Icons.videocam_rounded : Icons.call_rounded,
                color: BrokaColors.neonGreen,
                label: 'Accept',
                onTap: () {
                  // WebRtcService.start() has no internal guard of its own
                  // against being invoked twice, so this check is what
                  // actually prevents a rapid double-tap from requesting
                  // the camera/mic and opening the WebSocket/peer
                  // connection twice for the same call.
                  if (_accepted) return;
                  RingtoneService.instance.stop();
                  setState(() => _accepted = true);
                  CallForegroundService.start(
                      peerName: _peerName, isVideo: _isVideo);
                  CallKitService.instance.reportOutgoingCall(
                      roomId: _svc.roomId, peerName: _peerName, isVideo: _isVideo);
                  _svc.start();
                },
                large: true,
              ),
            ),
          ],
        ),
      );
    }

    // In-call controls for video: mute · video · flip · speaker, end below.
    if (_isVideo) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _CallBtn(
                icon:     _muted ? Icons.mic_off_rounded : Icons.mic_rounded,
                color:    _muted ? Colors.orange : BrokaColors.bgCard,
                label:    _muted ? 'Unmute' : 'Mute',
                onTap:    () { _svc.toggleMute(); setState(() => _muted = !_muted); },
                outlined: true,
                active:   _muted,
              ),
              const SizedBox(width: 16),
              _CallBtn(
                icon:     _videoOn ? Icons.videocam_rounded : Icons.videocam_off_rounded,
                color:    _videoOn ? BrokaColors.bgCard : Colors.orange,
                label:    _videoOn ? 'Video' : 'Video off',
                onTap:    () { _svc.toggleVideo(); setState(() => _videoOn = !_videoOn); },
                outlined: true,
                active:   !_videoOn,
              ),
              const SizedBox(width: 16),
              _CallBtn(
                icon:     Icons.cameraswitch_rounded,
                color:    BrokaColors.bgCard,
                label:    'Flip',
                onTap:    () => _svc.switchCamera(),
                outlined: true,
              ),
              const SizedBox(width: 16),
              _CallBtn(
                icon:     _speaker ? Icons.volume_up_rounded : Icons.volume_down_rounded,
                color:    _speaker ? BrokaColors.neonBlue : BrokaColors.bgCard,
                label:    _speaker ? 'Speaker' : 'Earpiece',
                onTap:    () async {
            final on = await _svc.toggleSpeaker();
            if (mounted) setState(() => _speaker = on);
          },
                outlined: true,
                active:   _speaker,
              ),
            ],
          ),
          const SizedBox(height: 22),
          _CallBtn(
            icon:  Icons.call_end_rounded,
            color: Colors.redAccent,
            label: 'End',
            onTap: () {
              if (_endingCall) return;
              _endingCall = true;
              _svc.hangup();
            },
            large: true,
          ),
        ],
      );
    }

    // In-call controls for audio: mute · end · speaker
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _CallBtn(
          icon:     _muted ? Icons.mic_off_rounded : Icons.mic_rounded,
          color:    _muted ? Colors.orange : BrokaColors.bgCard,
          label:    _muted ? 'Unmute' : 'Mute',
          onTap:    () { _svc.toggleMute(); setState(() => _muted = !_muted); },
          outlined: true,
          active:   _muted,
        ),
        const SizedBox(width: 24),
        _CallBtn(
          icon:  Icons.call_end_rounded,
          color: Colors.redAccent,
          label: 'End',
          onTap: () {
            if (_endingCall) return;
            _endingCall = true;
            _svc.hangup();
          },
          large: true,
        ),
        const SizedBox(width: 24),
        _CallBtn(
          icon:     _speaker ? Icons.volume_up_rounded : Icons.volume_down_rounded,
          color:    _speaker ? BrokaColors.neonBlue : BrokaColors.bgCard,
          label:    _speaker ? 'Speaker' : 'Earpiece',
          onTap:    () async {
            final on = await _svc.toggleSpeaker();
            if (mounted) setState(() => _speaker = on);
          },
          outlined: true,
          active:   _speaker,
        ),
      ],
    );
  }
}

// ── Ripple ring painter ────────────────────────────────────────────────────────

class _RippleRing extends StatelessWidget {
  final double progress;
  final Color  color;
  final double maxRadius;
  const _RippleRing({required this.progress, required this.color,
      required this.maxRadius});

  @override
  Widget build(BuildContext context) {
    final r = maxRadius * progress;
    final opacity = (1.0 - progress).clamp(0.0, 0.35);
    return Container(
      width: r * 2, height: r * 2,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: color.withOpacity(opacity), width: 1.5),
      ),
    );
  }
}

// ── Quality badge ──────────────────────────────────────────────────────────────

class _QualityBadge extends StatelessWidget {
  final CallQuality quality;
  const _QualityBadge({required this.quality});

  @override
  Widget build(BuildContext context) {
    // Driven by real inbound-audio packet loss and jitter sampled from
    // RTCPeerConnection.getStats() (see WebRtcService._sampleQuality).
    //
    // FIX (calling audit, 2026-09-14): this badge used to be computed
    // purely from how long the call had been up - under 5s "Connecting",
    // under 30s "Good", then "Excellent" for the rest of the call, no
    // matter what. It was a progress bar dressed as a diagnostic: a call
    // dropping 40% of its packets and relaying through TURN reported
    // "Excellent" at the 31 second mark. Showing nothing while quality is
    // genuinely unknown is more honest than showing a number we made up.
    if (quality == CallQuality.unknown) return const SizedBox.shrink();

    final (label, color, bars) = switch (quality) {
      CallQuality.good => ('Good', BrokaColors.neonGreen, 3),
      CallQuality.fair => ('Fair', BrokaColors.warning, 2),
      CallQuality.bad  => ('Weak', Colors.redAccent, 1),
      CallQuality.unknown => ('', BrokaColors.textLow, 0),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (int i = 0; i < 3; i++) ...[
          if (i > 0) const SizedBox(width: 2),
          AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            width: 3,
            height: 6.0 + i * 3,
            decoration: BoxDecoration(
              color: color.withOpacity(i < bars ? 1.0 : 0.25),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
        const SizedBox(width: 6),
        Text(label, style: TextStyle(
            color: color, fontSize: 9, fontWeight: FontWeight.w800,
            letterSpacing: 0.8)),
      ]),
    );
  }
}

// ── Call button ────────────────────────────────────────────────────────────────

class _CallBtn extends StatelessWidget {
  final IconData icon;
  final Color    color;
  final String   label;
  final VoidCallback onTap;
  final bool     large;
  final bool     outlined;
  final bool     active;

  const _CallBtn({
    required this.icon, required this.color,
    required this.label, required this.onTap,
    this.large = false, this.outlined = false, this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    final size = large ? 72.0 : 60.0;
    return GestureDetector(
      onTap: onTap,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: size, height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: outlined
                ? (active ? color.withOpacity(0.15) : Colors.transparent)
                : color,
            border: outlined
                ? Border.all(
                    color: active ? color : BrokaColors.border,
                    width: active ? 2.0 : 1.5)
                : null,
            boxShadow: large
                ? [BoxShadow(color: color.withOpacity(0.40),
                    blurRadius: 24, spreadRadius: 4)]
                : null,
          ),
          child: Icon(icon,
              color: outlined
                  ? (active ? color : BrokaColors.textMid)
                  : Colors.white,
              size: large ? 30 : 24),
        ),
        const SizedBox(height: 8),
        Text(label,
            style: const TextStyle(
                color: BrokaColors.textLow, fontSize: 10)),
      ]),
    );
  }
}
