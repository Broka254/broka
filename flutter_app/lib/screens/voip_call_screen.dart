// BROKA - In-App VoIP Call Screen
// Supports both audio and video calls (see WebRtcService.callType).
//
// On Home's visual system (2026-10-02): the constellation behind everything,
// a glow in the call's state colour around the person, the brand gradient
// on their ring, and the controls in a card like Home's. It was a flat black
// screen whose hints and button labels were drawn in the app's dimmest text
// colour - "they may not pick up" and "Mute" were close to invisible.
//
// It shows who is on the other end by name. A seller calling a buyer saw
// "Buyer": the direct chat passed that word instead of the buyer's name.
// Callers pass the name and, as `peerId`, who it is - and when all they have
// is a placeholder ("Buyer", "Seller"...) the screen looks the person up.

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../main.dart';
import '../widgets/chat_parts.dart' show kChatGradient;
import '../widgets/constellation_background.dart';
import '../services/webrtc_service.dart';
import '../services/api_service.dart';
import '../services/ringtone_service.dart';
import '../services/notification_service.dart';
import '../services/call_foreground_service.dart';
import '../services/callkit_service.dart';
import '../services/active_call.dart';

class VoipCallScreen extends StatefulWidget {
  const VoipCallScreen({super.key, this.animateBackground = true});

  /// False renders the constellation as one still frame - for tests.
  final bool animateBackground;

  /// Names that say which side someone is on, not who they are. A call
  /// screen headed "Buyer" told a seller nothing about which of their
  /// buyers they were ringing.
  static const _placeholderNames = {'', 'buyer', 'seller', 'user', 'someone'};

  static bool isPlaceholderName(String name) =>
      _placeholderNames.contains(name.trim().toLowerCase());

  /// How long the caller waits for an answer: as long as the callee's
  /// phone rings (NotificationService.showIncomingCall's ringFor).
  static const Duration noAnswerAfter = Duration(seconds: 45);
  @override
  State<VoipCallScreen> createState() => _VoipCallScreenState();
}

class _VoipCallScreenState extends State<VoipCallScreen>
    with TickerProviderStateMixin {

  late WebRtcService _svc;
  String _peerName    = '';
  String? _peerPhoto;          // inline base64; falls back to initials
  // Who the other person is, so a placeholder name can be replaced with
  // theirs (_resolvePeer). Empty from call sites that don't know.
  String _peerId      = '';
  // Peer presence at dial time, for the online dot on their face only.
  // null == unknown (older call sites).
  bool? _peerOnline;
  // Caller: a phone of theirs has the call ringing (the server's
  // callee_ringing). This, not their "last seen", is what decides between
  // "Calling" and "Ringing": an app that is closed is "offline" and still
  // rings from a push.
  bool _calleeAlerted = false;
  // Caller: nobody answered within [noAnswerAfter], and we hung up.
  bool _noAnswer = false;
  Timer? _noAnswerTimer;
  // Callee: this call stopped ringing elsewhere, or Accept was pressed on
  // its notification (NotificationService.ringEnded / answerRequests).
  StreamSubscription<String>? _ringEndedSub;
  StreamSubscription<String>? _answerSub;
  String _callToken = '';
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
    _peerId      = args['peerId']      as String? ?? '';
    _peerOnline  = args['peerOnline']  as bool?;
    _listingName = args['listingName'] as String? ?? '';
    _isCaller    = args['isCaller']    as bool?   ?? true;
    _listingId   = args['listingId']   as String? ?? '';
    _buyerId     = args['buyerId']     as String? ?? '';
    _callerRole  = args['callerRole']  as String? ?? 'buyer';
    _callType    = args['callType']    as String? ?? 'audio';
    final autoAccept = args['autoAccept'] as bool? ?? false;
    _callToken = callToken;
    unawaited(_resolvePeer());
    // This phone is on this call now: nothing else rings over it, and a
    // second screen for it never opens (ActiveCall).
    ActiveCall.instance.begin(roomId, answered: _isCaller || autoAccept);

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
      // This call's tone only: a call that ended must not silence another
      // one ringing now.
      RingtoneService.instance.stopFor(roomId);
      if (!mounted) return;
      setState(() => _callState = s);
      if (s == CallState.connected) {
        _noAnswerTimer?.cancel();
        _everConnected = true;
        CallKitService.instance.reportConnected(_svc.roomId);
        HapticFeedback.mediumImpact();
        _ringCtrl.stop();
        _connectedCtrl.forward(from: 0);
      }
      if (s == CallState.ended || s == CallState.failed) {
        _noAnswerTimer?.cancel();
        _logCallResultOnce();
        if (_ownsCall) CallForegroundService.stop();
        // Take the call out of iOS's native UI - otherwise the system keeps
        // showing an active call the user can't dismiss, with the audio
        // session still open.
        CallKitService.instance.endCall(_svc.roomId);
        Future.delayed(const Duration(seconds: 2), _closeOwnScreen);
      }
    };
    _svc.onDurationTick = (d) {
      if (mounted) setState(() => _duration = d);
    };
    _svc.onError = (msg) {
      if (mounted) setState(() => _errorMsg = msg);
    };
    _svc.onPeerRinging = () {
      if (mounted) setState(() => _calleeAlerted = true);
    };
    _svc.onLocalMediaReady = () {
      if (!mounted) return;
      // The mic (and camera, if granted) is open, so the permissions are
      // in place - only now can the foreground service start. It used to
      // start before WebRtcService had even asked for the microphone, and
      // on Android 14+ a microphone foreground service without that
      // permission throws inside the service and the OS kills the app: the
      // app closed the moment a call was placed or answered, and MIUI
      // showed "BROKA should be granted Microphone access".
      CallForegroundService.start(
          peerName: _peerName, isVideo: _isVideo && !_svc.cameraUnavailable);
      setState(() => _localMediaReady = true);
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
      // Caller starts immediately. The foreground service that keeps the
      // call alive through a screen lock starts from onLocalMediaReady.
      // iOS equivalent: registering with CallKit is what grants the call
      // audio session and keeps the app alive when backgrounded/locked.
      CallKitService.instance.reportOutgoingCall(
          roomId: roomId, peerName: _peerName, isVideo: _isVideo);
      _svc.start();
      // The caller's no-answer window - as long as the callee's phone
      // rings. There wasn't one: the connect timeout stood in for it and
      // ended every unanswered call after 30 seconds as a failure.
      _noAnswerTimer = Timer(VoipCallScreen.noAnswerAfter, () {
        // Answered and still connecting: the connect timeout owns that.
        if (!mounted || _everConnected || _endingCall || _svc.peerJoined) return;
        if (_callState != CallState.calling &&
            _callState != CallState.connecting) {
          return;
        }
        _endingCall = true;
        setState(() => _noAnswer = true);
        _svc.hangup(); // logged as "cancelled": the callee sees a missed call
      });
    } else if (autoAccept) {
      // The user already answered (Accept on the notification, or in
      // CallKit) - don't make them decide again.
      _accepted = true;
      RingtoneService.instance.stopFor(roomId);
      unawaited(ApiService.answerCall(roomId, callToken));
      CallKitService.instance.reportOutgoingCall(
          roomId: roomId, peerName: _peerName, isVideo: _isVideo);
      _svc.start();
    } else {
      // Callee: ring until Accept/Decline (or a safety timeout) - see
      // RingtoneService for why this is centralised rather than duplicated.
      RingtoneService.instance.play(
        autoStopAfter: const Duration(seconds: 45),
        roomId: roomId,
        onTimeout: () {
          if (!mounted) return;
          if (!_accepted && !_endingCall) {
            _endingCall = true;
            _svc.hangup(); // treated as a missed call
          }
        },
      );
      // The call can stop ringing without this screen hearing it: the
      // caller hangs up before we ever join their room, another phone
      // answers or declines, nobody answers. Before, the only teardown was
      // the 45-second ring timer - and any other call's teardown stopped
      // that timer with the ring - so a dead "Incoming call" screen could
      // stay up indefinitely.
      _ringEndedSub = NotificationService.instance.ringEnded.listen((ended) {
        if (ended != roomId || !mounted || _accepted || _endingCall) return;
        _endingCall = true;
        // Whoever ended it has recorded the outcome.
        _resultLogged = true;
        _svc.hangup();
      });
      _answerSub = NotificationService.instance.answerRequests.listen((r) {
        if (r == roomId) _acceptIncoming();
      });
    }
  }

  /// The callee answers.
  void _acceptIncoming() {
    // WebRtcService.start() has no internal guard of its own against being
    // invoked twice, so this check is what actually prevents a rapid
    // double-tap from requesting the camera/mic and opening the
    // WebSocket/peer connection twice for the same call.
    if (_accepted || _endingCall || !mounted) return;
    final roomId = _svc.roomId;
    RingtoneService.instance.stopFor(roomId);
    setState(() => _accepted = true);
    ActiveCall.instance.markAnswered(roomId);
    // Tell the server now rather than when our connection to the call
    // comes up, seconds later (media, a permission prompt, TURN): until
    // then it still reported the call as ringing, so this phone's own sweep
    // rang it again and posted a fresh Accept/Decline, and the callee's
    // other phones went on ringing.
    unawaited(ApiService.answerCall(roomId, _callToken));
    CallKitService.instance.reportOutgoingCall(
        roomId: roomId, peerName: _peerName, isVideo: _isVideo);
    _svc.start();
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

  /// Fills in the other person's name and photo when the call site could
  /// only pass a placeholder - the chat's profile fetch hadn't answered yet,
  /// say. Best-effort: on any failure the screen keeps what it was given.
  Future<void> _resolvePeer() async {
    if (_peerId.isEmpty) return;
    final needName = VoipCallScreen.isPlaceholderName(_peerName);
    final needPhoto = _peerPhoto == null || _peerPhoto!.isEmpty;
    if (!needName && !needPhoto) return;
    try {
      final info = await ApiService.getUserProfile(_peerId);
      if (!mounted) return;
      final name = (info['name'] as String?)?.trim() ?? '';
      final photo = info['profile_photo'] as String?;
      setState(() {
        if (needName && name.isNotEmpty) _peerName = name;
        if (needPhoto && photo != null && photo.isNotEmpty) _peerPhoto = photo;
        _peerOnline ??= info['is_online'] as bool?;
      });
    } catch (_) {}
  }

  /// "Buyer" or "Seller" - which side of the deal the OTHER person is on.
  /// callerRole is always the caller's role, whoever opened this screen.
  String get _peerRoleLabel {
    final callerIsBuyer = _callerRole == 'buyer';
    final peerIsBuyer = _isCaller ? !callerIsBuyer : callerIsBuyer;
    return peerIsBuyer ? 'Buyer' : 'Seller';
  }

  @override
  void dispose() {
    _noAnswerTimer?.cancel();
    _ringEndedSub?.cancel();
    _answerSub?.cancel();
    final roomId = _svc.roomId;
    RingtoneService.instance.stopFor(roomId);
    if (_ownsCall) {
      CallForegroundService.stop();
      CallKitService.instance.onEndedByNative = null;
      CallKitService.instance.onMuteChanged = null;
    }
    CallKitService.instance.endCall(roomId);
    ActiveCall.instance.end(roomId);
    _logCallResultOnce();
    _ringCtrl.dispose();
    _fadeCtrl.dispose();
    _connectedCtrl.dispose();
    unawaited(_svc.dispose());
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    super.dispose();
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// The foreground service, the CallKit hooks and the ring are shared by
  /// the whole app. A screen for a call that is no longer the phone's call
  /// (one a redial replaced, under the redial's screen) must not take them
  /// from the call that is.
  bool get _ownsCall {
    final active = ActiveCall.instance.roomId;
    return active == null || active == _svc.roomId;
  }

  /// Close this call's screen - not whatever is on top. A redial's screen
  /// sits above the call it replaced, and that call ending used to pop the
  /// redial's screen (hanging the new call up) and leave its own dead
  /// screen behind (review, 2026-10-08).
  void _closeOwnScreen() {
    if (!mounted) return;
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    if (route.isCurrent) {
      Navigator.of(context).pop();
    } else {
      Navigator.of(context).removeRoute(route);
    }
  }

  String get _durationLabel {
    final m = _duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = _duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String get _initials => _peerName.trim().split(' ')
      .map((w) => w.isEmpty ? '' : w[0].toUpperCase()).take(2).join();

  String get _displayName => _peerName.trim().isEmpty ? _peerRoleLabel : _peerName.trim();

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
      return const ColoredBox(
        color: BrokaColors.bgCard,
        child: Center(
          child: Icon(Icons.call_end_rounded, color: BrokaColors.danger, size: 40),
        ),
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

  // On the chat gradient, as the Inbox and the chat header draw someone
  // without a photo.
  Widget _initialsAvatar() => DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft, end: Alignment.bottomRight,
            colors: kChatGradient,
          ),
        ),
        child: Center(
          child: Text(
            _initials.isEmpty ? '?' : _initials,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 38,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      );

  Color get _stateColor {
    switch (_callState) {
      case CallState.connected:  return BrokaColors.neonGreen;
      // Amber, not the violet of "setting up": the call was up and is
      // trying to come back, which the user should be able to tell apart.
      case CallState.recovering: return BrokaColors.warning;
      case CallState.failed:     return BrokaColors.danger;
      case CallState.ended:      return BrokaColors.textMid;
      // Both "the far end has been alerted" states share one colour, so the
      // avatar ring visibly changes the moment the call actually reaches
      // them - gold = still our side, blue = their phone is ringing.
      case CallState.ringing:    return BrokaColors.neonBlue;
      // Gold until their phone has the call: the ring colour is the signal
      // that the far end was alerted.
      case CallState.calling:
        return _calleeAlerted ? BrokaColors.neonBlue : BrokaColors.gold;
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
        // WhatsApp's two words, on the same evidence: "Calling" while the
        // call has reached only the server, "Ringing" once a phone of
        // theirs acknowledged it (_calleeAlerted). It used to guess from
        // presence - "Trying to reach them…" for anyone not "online", which
        // a closed app always is, though its phone rings from a push.
        return _calleeAlerted ? 'Ringing…' : 'Calling…';
      case CallState.ringing:     return 'Connecting…';
      case CallState.recovering:  return 'Reconnecting…';
      case CallState.ended:
        if (_everConnected) return 'Call ended · $_durationLabel';
        if (_svc.remoteEndReason == 'declined') return 'Call declined';
        if (_noAnswer || _svc.remoteEndReason == 'no_answer') return 'No answer';
        return 'Call ended';
      case CallState.failed:      return _errorMsg ?? 'Call failed';
      default:                    return '';
    }
  }

  /// Sub-label under the state. Only shown pre-connection, and only when it
  /// adds something the main label doesn't: the caller's "Ringing…" earns
  /// "Their phone is ringing" because the whole point of splitting the two
  /// states is telling the user the call has left the building.
  String? get _stateDetail {
    if (!_isCaller && !_accepted &&
        (_callState == CallState.ringing || _callState == CallState.connecting)) {
      return _listingName.isEmpty ? null : 'About $_listingName';
    }
    if (_callState == CallState.connecting && _isCaller) {
      return 'Setting up the call';
    }
    if (_callState == CallState.recovering) {
      return 'The connection dropped - hold on';
    }
    if (_callState == CallState.calling && _isCaller) {
      return _calleeAlerted
          ? 'Their phone is ringing'
          : "Reaching their phone - they'll see you called if they can't answer";
    }
    if (_callState == CallState.ended && _isCaller && !_everConnected &&
        (_noAnswer || _svc.remoteEndReason == 'no_answer')) {
      return "They'll see that you called";
    }
    return null;
  }

  bool get _isRinging => _callState == CallState.calling ||
      _callState == CallState.ringing ||
      _callState == CallState.connecting;

  // ── Build ─────────────────────────────────────────────────────────────────

  bool get _isIncoming => !_isCaller && !_accepted &&
      (_callState == CallState.ringing || _callState == CallState.connecting);

  bool get _isOver =>
      _callState == CallState.ended || _callState == CallState.failed;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    // A small phone, or a big text size on any phone: a smaller face and
    // tighter gaps, so the controls stay on screen.
    final narrow = size.width < 360 || size.height < 640;
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Background: full-bleed remote video once it's flowing; otherwise
          // the constellation every other screen sits on, with a glow in
          // the call's state colour behind the person.
          if (_showRemoteVideo) ...[
            RTCVideoView(
              _svc.remoteRenderer,
              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            ),
            // Scrims so the top bar / controls stay legible over arbitrary
            // video content behind them.
            Positioned(
              top: 0, left: 0, right: 0, height: 170,
              child: IgnorePointer(
                child: DecoratedBox(
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
              bottom: 0, left: 0, right: 0, height: 260,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter, end: Alignment.topCenter,
                      colors: [Colors.black.withOpacity(0.65), Colors.transparent],
                    ),
                  ),
                ),
              ),
            ),
          ] else
            ConstellationBackground(
              animate: widget.animateBackground,
              child: IgnorePointer(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 600),
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      center: const Alignment(0, -0.32),
                      radius: 0.9,
                      colors: [
                        _stateColor.withOpacity(0.22),
                        _stateColor.withOpacity(0.0),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          SafeArea(
            // Fills the screen, and scrolls rather than overflowing when a
            // large text size makes it taller than a small phone.
            child: LayoutBuilder(
              builder: (context, box) => SingleChildScrollView(
                physics: const ClampingScrollPhysics(),
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: box.maxHeight),
                  child: IntrinsicHeight(
                    child: Column(children: [
                      _buildTopBar(),
                      const Spacer(flex: 2),
                      if (!_showRemoteVideo) _buildRippleAvatar(narrow),
                      SizedBox(height: narrow ? 14 : 26),
                      _buildPeerInfo(narrow),
                      SizedBox(height: narrow ? 12 : 18),
                      _buildStateRow(),
                      const Spacer(flex: 3),
                      SizedBox(height: narrow ? 12 : 20),
                      _buildControls(narrow),
                      SizedBox(height: narrow ? 12 : 24),
                    ]),
                  ),
                ),
              ),
            ),
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
    top: 64, right: 16,
    child: SafeArea(
      bottom: false,
      child: GestureDetector(
        onTap: () => _svc.switchCamera(),
        child: Container(
          width: 96, height: 132,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            color: BrokaColors.bgCard,
            border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.45), width: 1.2),
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
                      color: BrokaColors.textMid, size: 22),
                ),
        ),
      ),
    ),
  );

  // ── Top bar ───────────────────────────────────────────────────────────────

  Widget _buildTopBar() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
    child: Row(children: [
      const Flexible(
        child: _TopChip(
          icon: Icons.lock_rounded,
          label: 'End-to-end encrypted',
          color: BrokaColors.neonGreen,
        ),
      ),
      const SizedBox(width: 8),
      // Live quality once there is a call to measure; until then, what
      // kind of call this is.
      if (_callState == CallState.connected && _quality != CallQuality.unknown)
        _QualityBadge(quality: _quality)
      else
        _TopChip(
          icon: _isVideo ? Icons.videocam_rounded : Icons.call_rounded,
          label: _isVideo ? 'Video call' : 'Voice call',
          color: BrokaColors.neonBlue,
        ),
    ]),
  );

  // ── Avatar ────────────────────────────────────────────────────────────────

  Widget _buildRippleAvatar(bool narrow) {
    final face = narrow ? 100.0 : 128.0;
    final box  = face + (narrow ? 72 : 96);
    return AnimatedBuilder(
      animation: Listenable.merge([_ringCtrl, _connectedCtrl]),
      builder: (_, __) {
        return SizedBox(
          width: box, height: box,
          child: Stack(alignment: Alignment.center, children: [
            // Ripples in the state colour while the call is being put
            // through - they stop the moment it connects.
            if (_isRinging)
              for (int i = 0; i < 3; i++)
                _RippleRing(
                  progress: (_ringCtrl.value + i / 3) % 1.0,
                  color: _stateColor,
                  minRadius: face / 2 + 6,
                  maxRadius: box / 2,
                ),
            // A steady halo once connected.
            if (_callState == CallState.connected)
              Container(
                width: face + 34, height: face + 34,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: BrokaColors.neonGreen.withOpacity(0.28), width: 1.5),
                ),
              ),
            // The brand ring: the chat gradient, turning while the call is
            // being put through, still once it is up.
            Transform.rotate(
              angle: _isRinging ? _ringCtrl.value * 2 * 3.141592653589793 : 0,
              child: Container(
                width: face + 12, height: face + 12,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: SweepGradient(colors: _isOver
                      ? [_stateColor, _stateColor]
                      : [...kChatGradient, BrokaColors.neonCyan, kChatGradient.first]),
                  boxShadow: [BoxShadow(
                      color: _stateColor.withOpacity(0.35),
                      blurRadius: 26, spreadRadius: 2)],
                ),
              ),
            ),
            // The face - a bounce on connect.
            ScaleTransition(
              scale: CurvedAnimation(
                parent: _callState == CallState.connected
                    ? _connectedCtrl : kAlwaysCompleteAnimation,
                curve: Curves.elasticOut,
              ),
              child: Container(
                width: face, height: face,
                padding: const EdgeInsets.all(3),
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: BrokaColors.bg,
                ),
                // Real face when we have one, initials only as a fallback.
                child: ClipOval(child: SizedBox.expand(child: _buildAvatarContent())),
              ),
            ),
            // Online, as the chat header shows it - only when we know.
            if (_peerOnline == true && !_isOver)
              Positioned(
                left: box / 2 + face * 0.30,
                top: box / 2 + face * 0.30,
                child: Container(
                  width: 18, height: 18,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: BrokaColors.neonGreen,
                    border: Border.all(color: BrokaColors.bg, width: 3),
                  ),
                ),
              ),
          ]),
        );
      },
    );
  }

  // ── Who, and about what ───────────────────────────────────────────────────

  Widget _buildPeerInfo(bool narrow) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24),
    child: Column(children: [
      Text(
        _displayName,
        key: const Key('call-peer-name'),
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: BrokaColors.textHigh,
          fontSize: narrow ? 24 : 28,
          fontWeight: FontWeight.w800,
          shadows: const [Shadow(color: Colors.black54, blurRadius: 12)],
        ),
      ),
      const SizedBox(height: 10),
      // Which side of the deal they're on, and the listing - a card like
      // Home's chips rather than bare grey text.
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: BrokaColors.bgCard.withOpacity(0.86),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: BrokaColors.border),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [
                kChatGradient.first.withOpacity(0.35),
                kChatGradient.last.withOpacity(0.25),
              ]),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(_peerRoleLabel.toUpperCase(),
                style: const TextStyle(color: Colors.white, fontSize: 9.5,
                    fontWeight: FontWeight.w800, letterSpacing: 1.0)),
          ),
          if (_listingName.isNotEmpty) ...[
            const SizedBox(width: 8),
            const Icon(Icons.sell_outlined, size: 13, color: BrokaColors.textMid),
            const SizedBox(width: 5),
            Flexible(
              child: Text(_listingName,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: BrokaColors.textHigh,
                      fontSize: 12.5, fontWeight: FontWeight.w600)),
            ),
          ],
        ]),
      ),
    ]),
  );

  // ── State ─────────────────────────────────────────────────────────────────

  Widget _buildStateRow() {
    final isConnected = _callState == CallState.connected;
    final detail = _stateDetail;
    final color = _stateColor;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: color.withOpacity(0.12),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color.withOpacity(0.45)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            // A dot that breathes while the call is being put through.
            AnimatedBuilder(
              animation: _ringCtrl,
              builder: (_, __) => Container(
                width: 8, height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color.withOpacity(_isRinging
                      ? 0.45 + 0.55 * (1 - (_ringCtrl.value * 2 - 1).abs())
                      : 1.0),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 300),
                // On the theme's body style: on its own it would drop the
                // app's font for the platform default. (Not the ambient
                // DefaultTextStyle - this context is above the Scaffold's
                // Material, where that is the yellow-underlined fallback.)
                style: (Theme.of(context).textTheme.bodyMedium ?? const TextStyle()).merge(TextStyle(
                  color: color,
                  fontSize: isConnected ? 17 : 13.5,
                  fontWeight: isConnected ? FontWeight.w800 : FontWeight.w600,
                  letterSpacing: isConnected ? 1.6 : 0.3,
                  // Steady digits, so the timer doesn't jitter as it counts.
                  fontFeatures: const [FontFeature.tabularFigures()],
                )),
                // A failure says what to do about it ("Enable it in
                // Settings > Apps > BROKA > Permissions"): room for all of it.
                child: Text(_stateLabel, textAlign: TextAlign.center,
                    maxLines: _callState == CallState.failed ? 5 : 2,
                    overflow: TextOverflow.ellipsis),
              ),
            ),
          ]),
        ),
        // Only present pre-connection, and animated so the jump from
        // "Setting up the call" to "Their phone is ringing" reads as
        // progress rather than a flicker. In the readable text colour: it
        // was drawn in the dimmest one, where "they may not pick up" all
        // but disappeared on a phone screen.
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 250),
          child: detail == null
              ? const SizedBox(height: 0, width: 0)
              : Padding(
                  key: ValueKey(detail),
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    detail,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: BrokaColors.textMid,
                      fontSize: 12.5,
                      height: 1.35,
                    ),
                  ),
                ),
        ),
      ]),
    );
  }

  // ── Controls ──────────────────────────────────────────────────────────────

  void _hangUp() {
    if (_endingCall) return;
    _endingCall = true;
    _svc.hangup();
  }

  void _toggleMute() {
    _svc.toggleMute();
    setState(() => _muted = !_muted);
  }

  Future<void> _toggleSpeaker() async {
    final on = await _svc.toggleSpeaker();
    if (mounted) setState(() => _speaker = on);
  }

  Widget _muteButton() => _CallBtn(
    icon:   _muted ? Icons.mic_off_rounded : Icons.mic_rounded,
    color:  BrokaColors.warning,
    label:  _muted ? 'Unmute' : 'Mute',
    onTap:  _toggleMute,
    active: _muted,
  );

  Widget _speakerButton() => _CallBtn(
    icon:   _speaker ? Icons.volume_up_rounded : Icons.phone_in_talk_rounded,
    color:  BrokaColors.neonBlue,
    label:  _speaker ? 'Speaker' : 'Earpiece',
    onTap:  _toggleSpeaker,
    active: _speaker,
  );

  Widget _endButton() => _CallBtn(
    icon:     Icons.call_end_rounded,
    color:    BrokaColors.danger,
    label:    'End',
    onTap:    _hangUp,
    filled:   true,
    large:    true,
  );

  /// The controls, in a card like Home's over the constellation.
  Widget _dock(Widget child) => Container(
    margin: const EdgeInsets.symmetric(horizontal: 16),
    padding: const EdgeInsets.fromLTRB(12, 16, 12, 14),
    decoration: BoxDecoration(
      color: BrokaColors.bgCard.withOpacity(0.82),
      borderRadius: BorderRadius.circular(28),
      border: Border.all(color: BrokaColors.border),
      boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.35),
          blurRadius: 24, offset: const Offset(0, 8))],
    ),
    child: child,
  );

  Widget _buildControls(bool narrow) {
    if (_isOver) {
      return _dock(Center(
        child: _CallBtn(
          icon:   Icons.close_rounded,
          color:  BrokaColors.textHigh,
          label:  'Close',
          onTap:  () => Navigator.pop(context),
        ),
      ));
    }

    // Incoming call: decline / accept
    if (_isIncoming) {
      return _dock(Row(
        children: [
          Expanded(child: _CallBtn(
            icon:   Icons.call_end_rounded,
            color:  BrokaColors.danger,
            label:  'Decline',
            filled: true,
            large:  true,
            onTap: () {
              if (_endingCall) return;
              _endingCall = true;
              RingtoneService.instance.stopFor(_svc.roomId);
              ActiveCall.instance.settle(_svc.roomId);
              _declinedByMe = true;
              _svc.hangup();
            },
          )),
          // Accept - green, with a ring that keeps calling for attention.
          Expanded(child: AnimatedBuilder(
            animation: _ringCtrl,
            builder: (_, child) => Stack(
              alignment: Alignment.topCenter,
              clipBehavior: Clip.none,
              children: [
                Positioned(
                  top: -_ringCtrl.value * 10,
                  child: Opacity(
                    opacity: (1.0 - _ringCtrl.value).clamp(0.0, 0.5),
                    child: Container(
                      width: 72 + _ringCtrl.value * 20,
                      height: 72 + _ringCtrl.value * 20,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: BrokaColors.neonGreen, width: 1.5),
                      ),
                    ),
                  ),
                ),
                child!,
              ],
            ),
            child: _CallBtn(
              icon:   _isVideo ? Icons.videocam_rounded : Icons.call_rounded,
              color:  BrokaColors.neonGreen,
              label:  'Accept',
              filled: true,
              large:  true,
              onTap: _acceptIncoming,
            ),
          )),
        ],
      ));
    }

    // In-call controls for video: mute · video · flip · speaker, end below.
    if (_isVideo) {
      return _dock(Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(child: _muteButton()),
              Expanded(child: _CallBtn(
                icon:   _videoOn ? Icons.videocam_rounded : Icons.videocam_off_rounded,
                color:  BrokaColors.warning,
                label:  _videoOn ? 'Camera' : 'Camera off',
                onTap:  () { _svc.toggleVideo(); setState(() => _videoOn = !_videoOn); },
                active: !_videoOn,
              )),
              Expanded(child: _CallBtn(
                icon:  Icons.cameraswitch_rounded,
                color: BrokaColors.neonBlue,
                label: 'Flip',
                onTap: () => _svc.switchCamera(),
              )),
              Expanded(child: _speakerButton()),
            ],
          ),
          const SizedBox(height: 14),
          _endButton(),
        ],
      ));
    }

    // In-call controls for audio: mute · end · speaker
    return _dock(Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(child: _muteButton()),
        Expanded(child: _endButton()),
        Expanded(child: _speakerButton()),
      ],
    ));
  }
}

// ── Top-bar chip ───────────────────────────────────────────────────────────────

class _TopChip extends StatelessWidget {
  const _TopChip({required this.icon, required this.label, required this.color});

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: BrokaColors.bgCard.withOpacity(0.86),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: color.withOpacity(0.35)),
    ),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 12, color: color),
      const SizedBox(width: 6),
      Flexible(
        child: Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700,
                letterSpacing: 0.3)),
      ),
    ]),
  );
}

// ── Ripple ring ────────────────────────────────────────────────────────────────

class _RippleRing extends StatelessWidget {
  final double progress;
  final Color  color;
  final double minRadius;
  final double maxRadius;
  const _RippleRing({required this.progress, required this.color,
      required this.minRadius, required this.maxRadius});

  @override
  Widget build(BuildContext context) {
    final r = minRadius + (maxRadius - minRadius) * progress;
    final opacity = (1.0 - progress).clamp(0.0, 0.45);
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
      CallQuality.bad  => ('Weak', BrokaColors.danger, 1),
      CallQuality.unknown => ('', BrokaColors.textLow, 0),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: BrokaColors.bgCard.withOpacity(0.86),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.45)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
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
            color: color, fontSize: 11, fontWeight: FontWeight.w700,
            letterSpacing: 0.3)),
      ]),
    );
  }
}

// ── Call button ────────────────────────────────────────────────────────────────

/// A round control with its label underneath.
///
/// [filled] is a call action - accept, decline, end - in its colour with a
/// glow. Otherwise it is a toggle on the dock's card: quiet until [active],
/// then lit in [color].
class _CallBtn extends StatelessWidget {
  final IconData icon;
  final Color    color;
  final String   label;
  final VoidCallback onTap;
  final bool     large;
  final bool     filled;
  final bool     active;

  const _CallBtn({
    required this.icon, required this.color,
    required this.label, required this.onTap,
    this.large = false, this.filled = false, this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    final size = large ? 68.0 : 56.0;
    final Color iconColor = filled
        ? Colors.white
        : (active ? color : BrokaColors.textHigh);
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: size, height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: filled
                    ? LinearGradient(
                        begin: Alignment.topLeft, end: Alignment.bottomRight,
                        colors: [color, Color.lerp(color, Colors.black, 0.25)!],
                      )
                    : null,
                color: filled
                    ? null
                    : (active ? color.withOpacity(0.18) : BrokaColors.bgMid.withOpacity(0.75)),
                border: filled
                    ? null
                    : Border.all(
                        color: active ? color : BrokaColors.border,
                        width: active ? 1.6 : 1.2),
                boxShadow: filled
                    ? [BoxShadow(color: color.withOpacity(0.40),
                        blurRadius: 20, spreadRadius: 2)]
                    : null,
              ),
              child: Icon(icon, color: iconColor, size: large ? 30 : 24),
            ),
            const SizedBox(height: 8),
            Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: active ? color : BrokaColors.textMid,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}
