// Voice mode - talking to Zeno the way one talks to Siri.
//
// Full screen, over the typed conversation rather than instead of it: every
// spoken turn goes through the screen's own send path, so it is in the
// conversation when voice mode closes, and the keyboard is one tap back to
// typing. The session itself is ZenoVoiceController's - the same Deepgram
// session, transcript and state machine the floating voice card uses - so
// nothing about listening is written twice. This file only draws it:
//
//   it opens as a circle growing out of the microphone button;
//   the orb (zeno_orb.dart) shows what Zeno is doing, in a glow that follows
//   it, and the conversation is written over it as it happens: what the user
//   said, dimmer, then Zeno's reply, written out as the voice says it;
//   an action card shows what it is doing, or asks before a call;
//   Pause and End, each labelled, and "Tap to show keyboard" under them.
//
// Like the voice card, it can't outlive the tree that opened it: an open
// microphone behind a popped screen is exactly the failure brief §25 names.
//
// 2026-09-27: it is mounted once, above the Navigator, by Zeno's session
// (zeno_session_host.dart), so that opening a screen no longer ends the
// conversation: the view shrinks back into a pill that keeps listening
// ([expanded] false, the microphone still open) and grows out of it again.
//
// 2026-10-10: one voice mode for every Zeno conversation. The Buying Agent
// and a listing's questions used to open a compact card over the chat
// instead - the same microphone, looking like a different feature. They
// mount this with their own controller now, with [hints] of their own. And
// it is drawn in Home's language: the constellation behind it, Home's header
// and controls, and Zeno's thinking waves.
//
// 2026-10-14: the layout of a live voice conversation. Captions sit over the
// orb instead of under it and read as a conversation - the user's words
// above, Zeno's below, written as they are spoken ([captionProgress]) - with
// "Tap to interrupt" while Zeno talks; the lone round buttons became Pause
// (the microphone rests, the screen stays) and End, labelled; and the
// header gained a captions switch. No telephone symbols: this is Zeno, not a
// call (BROKA's real calls are elsewhere).
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable;

import '../../../main.dart' show BrokaColors, ZoneGlowText;
import '../../../services/broka_tts.dart' show spokenSoFar;
import '../../../services/zeno_voice_controller.dart';
import '../../../theme/motion.dart';
import '../../../widgets/collapsing_screen_header.dart' show BrokaHeaderButton;
import '../../../widgets/constellation_background.dart';
import '../../../widgets/zeno_avatar.dart';
import '../../buy_agent/presentation/widgets/agent_hud.dart' show AgentThinkingWave;
import 'zeno_orb.dart';

class ZenoLiveOverlay extends StatefulWidget {
  const ZenoLiveOverlay({
    super.key,
    required this.controller,
    required this.child,
    required this.onClose,
    required this.onKeyboard,
    required this.onInterrupt,
    this.zenoSays,
    this.youSaid,
    this.captionProgress,
    this.thinking = false,
    this.actionCard,
    this.burst = 0,
    this.muted = false,
    this.onToggleMute,
    this.paused = false,
    this.onPause,
    this.onResume,
    this.expanded = true,
    this.origin = const Alignment(0.82, 0.9),
    this.onMinimize,
    this.hints = defaultHints,
    this.thinkingLabel = 'Zeno is thinking',
  });

  /// What the assistant can be asked, a new one every few seconds while
  /// nothing has been said.
  static const defaultHints = [
    // Things people would really say, each one a thing Zeno does (search,
    // the Buying Agent, guides, navigation, calls) - "Open my inbox" taught
    // nobody what an assistant is for.
    '"Find me a clean iPhone 13 under 45k near Westlands"',
    '"What should I ask for my 2016 Vitz?"',
    '"Hunt down a PS5 and tell me when one drops"',
    '"Who sells the cheapest solar panels in Nakuru?"',
    '"Show me laptops a student can afford"',
    '"How do I get my store on the web?"',
    '"Why isn\'t my sofa selling?"',
    '"Call the seller of that fridge"',
    '"Is a 20k deposit on a car a scam?"',
    '"Take me to my deals"',
  ];

  final ZenoVoiceController controller;
  final Widget child;

  /// Zeno's latest reply in this session, if any.
  final String? zenoSays;

  /// What the user last said to Zeno - kept above Zeno's reply, dimmer, so
  /// the captions read as the exchange they are. Null leaves it out.
  final String? youSaid;

  /// How far through [zenoSays] the voice has got, 0..1 (BrokaTts's
  /// captionProgress): the reply is written out as it is spoken. Null, or a
  /// null value, shows the reply whole - muted, no audio, or already said.
  final ValueListenable<double?>? captionProgress;

  /// The screen is waiting on Zeno's reply.
  final bool thinking;

  /// What Zeno is doing, or asking to do.
  final Widget? actionCard;

  /// Goes up by one each time an action is taken - the orb's shockwave.
  final int burst;

  final bool muted;
  final VoidCallback? onToggleMute;

  /// Pause: the microphone is off and the view stays up (the owner closes
  /// the controller and says so with [paused]; the view would otherwise go
  /// away with the microphone). Without [onPause] there is no Pause button.
  final bool paused;
  final VoidCallback? onPause;
  final VoidCallback? onResume;

  final VoidCallback onClose;
  final VoidCallback onKeyboard;

  /// Stop Zeno mid-sentence and listen.
  final VoidCallback onInterrupt;

  /// Whether the full view shows while the microphone is open. False is the
  /// session docked in its pill, still listening.
  final bool expanded;

  /// Where the view grows from and shrinks back into.
  final Alignment origin;

  /// The top bar's chevron: keep Zeno on, out of the way. Without it the
  /// chevron closes, as [onClose] does.
  final VoidCallback? onMinimize;

  /// Examples of what to say, for whichever conversation this is.
  final List<String> hints;

  /// What Zeno is doing while it works on a reply - "Zeno is hunting" while
  /// the Buying Agent searches.
  final String thinkingLabel;

  @override
  State<ZenoLiveOverlay> createState() => _ZenoLiveOverlayState();
}

class _ZenoLiveOverlayState extends State<ZenoLiveOverlay> with SingleTickerProviderStateMixin {
  late final AnimationController _reveal =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 650));
  late final _revealCurve =
      CurvedAnimation(parent: _reveal, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onController);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Here rather than initState: whether motion is reduced is a MediaQuery
    // lookup, which initState may not make.
    _onController();
  }

  @override
  void didUpdateWidget(ZenoLiveOverlay old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onController);
      widget.controller.addListener(_onController);
    }
    if (old.expanded != widget.expanded || old.paused != widget.paused || old.controller != widget.controller) {
      _onController();
    }
  }

  void _onController() {
    // A paused session has its microphone closed on purpose and keeps the
    // view: without this the view went away with the microphone.
    final open = (widget.controller.isOpen || widget.paused) && widget.expanded;
    if (!mounted) return;
    final still = BrokaMotion.reduced(context);
    if (open && _reveal.status != AnimationStatus.forward && _reveal.value < 1) {
      still ? _reveal.value = 1 : _reveal.forward();
    } else if (!open && _reveal.status != AnimationStatus.reverse && _reveal.value > 0) {
      still ? _reveal.value = 0 : _reveal.reverse();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onController);
    // The microphone goes with the screen - see the file header.
    widget.controller.stopForDispose();
    _revealCurve.dispose();
    _reveal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      widget.child,
      AnimatedBuilder(
        animation: _reveal,
        builder: (context, _) {
          if (_reveal.value == 0) return const SizedBox.shrink();
          return Positioned.fill(
            child: ClipPath(
              clipper: _RevealClipper(_revealCurve.value, widget.origin),
              child: _LiveView(overlay: widget),
            ),
          );
        },
      ),
    ]);
  }
}

/// A circle growing from [origin] until it covers the screen.
class _RevealClipper extends CustomClipper<Path> {
  _RevealClipper(this.t, this.origin);
  final double t;
  final Alignment origin;

  @override
  Path getClip(Size size) {
    final c = origin.alongSize(size);
    final far = [
      Offset.zero,
      Offset(size.width, 0),
      Offset(0, size.height),
      Offset(size.width, size.height),
    ].map((p) => (p - c).distance).reduce(math.max);
    return Path()..addOval(Rect.fromCircle(center: c, radius: 28 + (far - 28) * t));
  }

  @override
  bool shouldReclip(_RevealClipper old) => old.t != t || old.origin != origin;
}

class _LiveView extends StatefulWidget {
  const _LiveView({required this.overlay});

  final ZenoLiveOverlay overlay;

  @override
  State<_LiveView> createState() => _LiveViewState();
}

class _LiveViewState extends State<_LiveView> {
  /// The captions switch in the header. Per opening of voice mode: a user
  /// who wants only the orb turns them off and gets them back next time.
  bool _captions = true;

  ZenoLiveOverlay get overlay => widget.overlay;

  ZenoOrbMode _mode(VoiceSessionState s, {required bool paused}) {
    if (paused) return ZenoOrbMode.waking;
    if (overlay.thinking) return ZenoOrbMode.thinking;
    return switch (s) {
      VoiceSessionState.idle ||
      VoiceSessionState.connecting ||
      VoiceSessionState.reconnecting =>
        ZenoOrbMode.waking,
      VoiceSessionState.listening ||
      VoiceSessionState.processing ||
      VoiceSessionState.readyToSend =>
        ZenoOrbMode.listening,
      VoiceSessionState.sendingToZeno => ZenoOrbMode.thinking,
      VoiceSessionState.speaking => ZenoOrbMode.speaking,
      VoiceSessionState.error => ZenoOrbMode.error,
    };
  }

  static String status(VoiceSessionState s,
      {required bool thinking,
      required bool hearing,
      bool paused = false,
      String thinkingLabel = 'Zeno is thinking'}) {
    // "Zeno is hunting" -> "Hunting…".
    final working = thinkingLabel.startsWith('Zeno is ')
        ? '${thinkingLabel[8].toUpperCase()}${thinkingLabel.substring(9)}…'
        : 'Thinking…';
    if (paused) return 'Paused';
    if (thinking) return working;
    return switch (s) {
      VoiceSessionState.idle || VoiceSessionState.connecting => 'Waking up…',
      VoiceSessionState.reconnecting => 'Reconnecting…',
      VoiceSessionState.listening => hearing ? "I'm listening" : 'Listening…',
      VoiceSessionState.processing || VoiceSessionState.readyToSend => 'Got it…',
      VoiceSessionState.sendingToZeno => working,
      VoiceSessionState.speaking => 'Speaking',
      VoiceSessionState.error => 'Voice stopped',
    };
  }

  /// The glow behind the orb: the colour of what Zeno is doing.
  Color _glow(ZenoOrbMode mode) => switch (mode) {
        ZenoOrbMode.waking => BrokaColors.neonPurple,
        ZenoOrbMode.listening => BrokaColors.neonBlue,
        ZenoOrbMode.thinking => BrokaColors.neonPurple,
        ZenoOrbMode.speaking => BrokaColors.neonCyan,
        ZenoOrbMode.error => BrokaColors.danger,
      };

  @override
  Widget build(BuildContext context) {
    final c = overlay.controller;
    // Home's sky, opaque: the conversation underneath is kept (closing
    // voice returns to it) but not read through the captions.
    return Material(
      type: MaterialType.transparency,
      child: ConstellationBackground(
        animate: !BrokaMotion.reduced(context),
        child: DecoratedBox(
          // Zeno's colour washing down from the top, as on Zeno's chat.
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(0, -0.35),
              radius: 1.0,
              colors: [BrokaColors.neonPurple.withOpacity(0.16), Colors.transparent],
              stops: const [0.0, 0.7],
            ),
          ),
          child: SafeArea(
            child: LayoutBuilder(builder: (context, box) {
              // Short screens (and large text) give the stage less room; the
              // orb takes whatever is left, so nothing is ever pushed off.
              final tall = box.maxHeight >= 640;
              return AnimatedBuilder(
                animation: c,
                builder: (context, _) {
                  final state = c.state;
                  // Paused is the owner's word, but only while the
                  // microphone really is closed: resuming opens it before
                  // the owner has said so, and the view must not show
                  // "Paused" over a microphone that is already coming back.
                  final paused = overlay.paused && !c.isOpen;
                  final heard = '${c.transcript.text} ${c.interim}'.trim();
                  final thinking = overlay.thinking || state == VoiceSessionState.sendingToZeno;
                  return Column(children: [
                    _TopBar(
                      status: status(state,
                          thinking: overlay.thinking,
                          hearing: heard.isNotEmpty || c.level > 0.2,
                          paused: paused,
                          thinkingLabel: overlay.thinkingLabel),
                      live: !paused &&
                          (state == VoiceSessionState.listening ||
                              thinking ||
                              state == VoiceSessionState.speaking),
                      muted: overlay.muted,
                      onToggleMute: overlay.onToggleMute,
                      captions: _captions,
                      onToggleCaptions: () => setState(() => _captions = !_captions),
                      onClose: overlay.onMinimize ?? overlay.onClose,
                      minimizes: overlay.onMinimize != null,
                    ),
                    Expanded(child: _stage(c, state, heard: heard, thinking: thinking, paused: paused)),
                    AnimatedSwitcher(
                      duration: BrokaMotion.of(context, BrokaMotion.standard),
                      child: overlay.actionCard == null
                          ? const SizedBox(key: ValueKey('none'), height: 0, width: double.infinity)
                          : Padding(
                              key: const ValueKey('card'),
                              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                              child: overlay.actionCard,
                            ),
                    ),
                    SizedBox(height: tall ? 12 : 6),
                    _Controls(
                      paused: paused,
                      canPause: overlay.onPause != null,
                      onPause: overlay.onPause ?? () {},
                      onResume: overlay.onResume ?? () {},
                      onClose: overlay.onClose,
                    ),
                    SizedBox(height: tall ? 8 : 4),
                    _KeyboardLink(onTap: overlay.onKeyboard),
                    SizedBox(height: tall ? 14 : 6),
                  ]);
                },
              );
            }),
          ),
        ),
      ),
    );
  }

  /// The orb with the conversation written over it.
  Widget _stage(
    ZenoVoiceController c,
    VoiceSessionState state, {
    required String heard,
    required bool thinking,
    required bool paused,
  }) {
    final mode = _mode(state, paused: paused);
    final error = state == VoiceSessionState.error;
    final speaking = state == VoiceSessionState.speaking && !paused;
    final reply = overlay.zenoSays ?? '';
    final words = _pickWords(
      state: state,
      heard: heard,
      youSaid: overlay.youSaid ?? '',
      zenoSays: reply,
      thinking: thinking,
      paused: paused,
    );
    // Only a stage with nothing to say shows the orb at full strength and
    // the hints under it; with words, the orb is the glow they sit in.
    final idle = words == _Words.hints && _captions;
    final showWords = _captions && words != _Words.hints;
    return LayoutBuilder(builder: (context, room) {
      // Never taller than its room: on a short phone at large text, with a
      // card up, that is under 64.
      final orb = math
          .min(room.maxWidth * 0.9, room.maxHeight * 0.96)
          .clamp(math.min(64.0, room.maxHeight), 360.0)
          .toDouble();
      final canSend = c.hasSendableText && !thinking && !paused && !error;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: switch (state) {
          VoiceSessionState.speaking => overlay.onInterrupt,
          VoiceSessionState.error => c.open,
          _ => null,
        },
        child: Stack(alignment: Alignment.center, children: [
          // The glow, and the orb in it (a hologram at the heart, not Zeno's
          // face: voice mode is the assistant at work, and a mascot in the
          // middle read as a toy). Raised while the hints are under it.
          AnimatedAlign(
            duration: BrokaMotion.of(context, BrokaMotion.standard),
            curve: BrokaMotion.enter,
            alignment: Alignment(0.0, idle ? -0.3 : 0.0),
            child: Stack(alignment: Alignment.center, children: [
              IgnorePointer(
                child: Container(
                  width: orb * 1.12,
                  height: orb * 1.12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(colors: [
                      _glow(mode).withOpacity(paused ? 0.10 : 0.16 + 0.2 * c.level.clamp(0.0, 1.0)),
                      _glow(mode).withOpacity(0.0),
                    ]),
                  ),
                ),
              ),
              AnimatedOpacity(
                duration: BrokaMotion.of(context, BrokaMotion.standard),
                opacity: paused ? 0.4 : (showWords ? 0.32 : 1.0),
                child: ZenoOrb(
                    mode: mode, level: paused ? 0.0 : c.level, burst: overlay.burst, size: orb, hologram: true),
              ),
            ]),
          ),
          if (showWords)
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 6),
                child: _Transcript(
                  words: words,
                  heard: heard,
                  interim: c.interim,
                  youSaid: overlay.youSaid ?? '',
                  zenoSays: reply,
                  progress: overlay.captionProgress,
                  speaking: speaking,
                  thinking: thinking,
                  error: c.errorMessage,
                  errorReference: c.errorReference,
                  thinkingLabel: overlay.thinkingLabel,
                ),
              ),
            ),
          // Errors say they are errors even with captions off.
          if (!_captions && error)
            Positioned.fill(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 26),
                child: _Transcript(
                  words: _Words.error,
                  heard: '',
                  interim: '',
                  youSaid: '',
                  zenoSays: '',
                  progress: null,
                  speaking: false,
                  thinking: false,
                  error: c.errorMessage,
                  errorReference: c.errorReference,
                  thinkingLabel: overlay.thinkingLabel,
                ),
              ),
            ),
          if (idle)
            Align(
              alignment: const Alignment(0, 0.92),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: _Hints(examples: overlay.hints, englishOnly: c.languageUnsupported),
              ),
            ),
          // What a tap does, in Kimi's words: a tap anywhere on the stage.
          Align(
            alignment: const Alignment(0, 1.0),
            child: Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: AnimatedSwitcher(
                duration: BrokaMotion.of(context, BrokaMotion.quick),
                child: canSend
                    ? _SendNow(key: const ValueKey('send'), onTap: c.submit)
                    : speaking
                        ? const _TapHint(key: ValueKey('interrupt'), text: 'Tap to interrupt')
                        : const SizedBox(key: ValueKey('nohint'), height: 0, width: 0),
              ),
            ),
          ),
        ]),
      );
    });
  }
}

/// Home's header language: a bare chevron, Zeno's face and glowing name,
/// what it is doing beside a live dot, and square controls on the right.
class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.status,
    required this.muted,
    required this.onClose,
    required this.captions,
    required this.onToggleCaptions,
    this.live = false,
    this.onToggleMute,
    this.minimizes = false,
  });

  final String status;
  final bool muted;
  final bool live;
  final bool minimizes;
  final bool captions;
  final VoidCallback onToggleCaptions;
  final VoidCallback? onToggleMute;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(6, 6, 12, 10),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: BrokaColors.border.withOpacity(0.6))),
        ),
        child: Row(children: [
          IconButton(
            tooltip: minimizes ? 'Keep Zeno on while you browse' : 'Close voice',
            onPressed: onClose,
            icon: const Icon(Icons.keyboard_arrow_down_rounded, color: BrokaColors.textHigh, size: 30),
          ),
          const ZenoAvatar(size: 34, glow: true),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              const ZoneGlowText('Zeno',
                  gradient: [BrokaColors.neonPurple, BrokaColors.neonBlue],
                  fontSize: 19,
                  maxLines: 1,
                  letterSpacing: 1.6),
              const SizedBox(height: 3),
              Row(children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: live ? BrokaColors.neonGreen : BrokaColors.textMid,
                    boxShadow: live ? [BoxShadow(color: BrokaColors.neonGreen.withOpacity(0.7), blurRadius: 6)] : null,
                  ),
                ),
                const SizedBox(width: 5),
                Flexible(
                  child: AnimatedSwitcher(
                    duration: BrokaMotion.quick,
                    layoutBuilder: (current, previous) => Stack(
                        alignment: Alignment.centerLeft, children: [...previous, if (current != null) current]),
                    child: Text(status,
                        key: ValueKey(status),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: BrokaColors.textMid, fontSize: 12, letterSpacing: 0.3)),
                  ),
                ),
              ]),
            ]),
          ),
          const SizedBox(width: 8),
          BrokaHeaderButton(
            icon: captions ? Icons.subtitles_rounded : Icons.subtitles_off_rounded,
            active: captions,
            tooltip: captions ? 'Hide captions' : 'Show captions',
            onTap: onToggleCaptions,
          ),
          const SizedBox(width: 8),
          BrokaHeaderButton(
            icon: muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
            active: !muted,
            tooltip: muted ? "Read Zeno's replies aloud" : 'Mute Zeno',
            onTap: onToggleMute ?? () {},
          ),
        ]),
      );
}

/// What the stage shows in words. One enum so the stage and the transcript
/// agree on which it is.
enum _Words { error, paused, you, thinking, exchange, hints }

/// Which of the above the stage is showing, from where the conversation is.
_Words _pickWords({
  required VoiceSessionState state,
  required String heard,
  required String youSaid,
  required String zenoSays,
  required bool thinking,
  required bool paused,
}) {
  if (state == VoiceSessionState.error) return _Words.error;
  if (paused) return _Words.paused;
  // Zeno speaking: its words, whatever the microphone makes of the room.
  if (state == VoiceSessionState.speaking && zenoSays.isNotEmpty) return _Words.exchange;
  // The user is talking (or has words waiting to be sent).
  if (heard.isNotEmpty) return _Words.you;
  // What Zeno last said stays up, dimmer, until the user speaks again.
  if (!thinking && zenoSays.isNotEmpty && state != VoiceSessionState.connecting) return _Words.exchange;
  if (thinking) return _Words.thinking;
  return _Words.hints;
}

/// The transcript, over the orb: the exchange as it is happening.
class _Transcript extends StatelessWidget {
  const _Transcript({
    required this.words,
    required this.heard,
    required this.interim,
    required this.youSaid,
    required this.zenoSays,
    required this.progress,
    required this.speaking,
    required this.thinking,
    required this.error,
    required this.errorReference,
    required this.thinkingLabel,
  });

  final _Words words;
  final String heard;
  final String interim;
  final String youSaid;
  final String zenoSays;
  final ValueListenable<double?>? progress;
  final bool speaking;
  final bool thinking;
  final String? error;
  final String? errorReference;
  final String thinkingLabel;

  /// Legible over the orb's glow, whatever is behind a letter.
  static const _lift = [Shadow(color: BrokaColors.bg, blurRadius: 14), Shadow(color: BrokaColors.bg, blurRadius: 4)];

  @override
  Widget build(BuildContext context) {
    final Widget child;
    switch (words) {
      case _Words.error:
        child = Column(key: const ValueKey('error'), mainAxisSize: MainAxisSize.min, children: [
          Text(error ?? "Voice isn't available right now.",
              textAlign: TextAlign.center,
              style: const TextStyle(color: BrokaColors.textHigh, fontSize: 17, height: 1.35, shadows: _lift)),
          if (errorReference != null) ...[
            const SizedBox(height: 6),
            Text(errorReference!, style: const TextStyle(color: BrokaColors.textMid, fontSize: 11)),
          ],
          const SizedBox(height: 6),
          const Text('Tap Zeno to try again', style: TextStyle(color: BrokaColors.textMid, fontSize: 12.5)),
        ]);
      case _Words.paused:
        child = const Column(key: ValueKey('paused'), mainAxisSize: MainAxisSize.min, children: [
          Text('Paused',
              textAlign: TextAlign.center,
              style: TextStyle(color: BrokaColors.textHigh, fontSize: 26, fontWeight: FontWeight.w700, shadows: _lift)),
          SizedBox(height: 6),
          Text("Zeno isn't listening. Tap Resume when you're ready.",
              textAlign: TextAlign.center,
              style: TextStyle(color: BrokaColors.textMid, fontSize: 13.5, height: 1.35)),
        ]);
      case _Words.you:
        // The words as they are heard, the still-being-revised tail lighter.
        child = _Line(
          key: const ValueKey('you'),
          text: heard,
          interim: interim,
          style: const TextStyle(color: Colors.white, fontSize: 25, fontWeight: FontWeight.w700, height: 1.32),
        );
      case _Words.thinking:
        child = Column(
          key: const ValueKey('thinking'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (youSaid.isNotEmpty) ...[_you(youSaid), const SizedBox(height: 18)],
            // The same waves as every Zeno chat.
            AgentThinkingWave(label: thinkingLabel, padding: EdgeInsets.zero, alignment: Alignment.centerLeft),
          ],
        );
      case _Words.hints:
        // The stage draws the hints itself; there are no words to write.
        child = const SizedBox.shrink(key: ValueKey('hints'));
      case _Words.exchange:
        child = Column(
          key: ValueKey('exchange:$zenoSays'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (youSaid.isNotEmpty) ...[_you(youSaid), const SizedBox(height: 16)],
            _ZenoWords(text: zenoSays, progress: speaking ? progress : null, dim: !speaking),
          ],
        );
    }
    final centered = words == _Words.error || words == _Words.paused;
    return AnimatedSwitcher(
      duration: BrokaMotion.of(context, const Duration(milliseconds: 320)),
      transitionBuilder: (c, a) => FadeTransition(
        opacity: a,
        child: SlideTransition(
          position: Tween(begin: const Offset(0, 0.06), end: Offset.zero).animate(a),
          child: c,
        ),
      ),
      layoutBuilder: (current, previous) => Stack(
          alignment: centered ? Alignment.center : Alignment.centerLeft,
          children: [...previous, if (current != null) current]),
      child: Align(
        key: ValueKey('${words.name}:${zenoSays.hashCode}:${youSaid.hashCode}'),
        alignment: centered ? Alignment.center : Alignment.centerLeft,
        // A reply longer than the room scrolls rather than being cut off.
        child: SingleChildScrollView(child: child),
      ),
    );
  }

  /// What the user said: the quieter half of the exchange.
  Widget _you(String text) => Text(text,
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: BrokaColors.textMid.withOpacity(0.95),
        fontSize: 17,
        height: 1.35,
        fontWeight: FontWeight.w600,
        shadows: _lift,
      ));
}

/// A line of what is being said, the still-being-revised end of it lighter.
class _Line extends StatelessWidget {
  const _Line({super.key, required this.text, required this.interim, required this.style});

  final String text;
  final String interim;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final base = style.copyWith(shadows: _Transcript._lift);
    final settled = interim.isNotEmpty && text.endsWith(interim)
        ? text.substring(0, text.length - interim.length)
        : text;
    return Text.rich(
      TextSpan(children: [
        TextSpan(text: settled, style: base),
        if (settled != text) TextSpan(text: interim, style: base.copyWith(color: base.color!.withOpacity(0.55))),
      ]),
      maxLines: 8,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// Zeno's words, written out as they are spoken. Laid out whole from the
/// start with the words still to come drawn clear, so the text never
/// re-wraps under the reader's eye as it grows.
class _ZenoWords extends StatelessWidget {
  const _ZenoWords({required this.text, required this.progress, required this.dim});

  final String text;
  final ValueListenable<double?>? progress;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    final base = TextStyle(
      color: BrokaColors.textHigh.withOpacity(dim ? 0.62 : 1),
      fontSize: 25,
      height: 1.32,
      fontWeight: FontWeight.w600,
      shadows: _Transcript._lift,
    );
    Widget written(double? through) {
      final shown = through == null ? text : spokenSoFar(text, through);
      return Text.rich(TextSpan(children: [
        TextSpan(text: shown, style: base),
        if (shown.length < text.length)
          TextSpan(text: text.substring(shown.length), style: base.copyWith(color: Colors.transparent, shadows: const [])),
      ]));
    }

    final p = progress;
    if (p == null) return written(null);
    return ValueListenableBuilder<double?>(valueListenable: p, builder: (_, through, __) => written(through));
  }
}

/// A small instruction under the stage - "Tap to interrupt".
class _TapHint extends StatelessWidget {
  const _TapHint({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(text, style: const TextStyle(color: BrokaColors.textMid, fontSize: 13, letterSpacing: 0.6)),
      );
}

/// What the words waiting to be sent can do, for the moment before they go
/// by themselves (the controller sends a finished utterance after a beat).
class _SendNow extends StatelessWidget {
  const _SendNow({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color: BrokaColors.bgCard.withOpacity(0.86),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.45)),
            ),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.arrow_upward_rounded, size: 16, color: BrokaColors.neonCyan),
              SizedBox(width: 6),
              Text('Send now', style: TextStyle(color: BrokaColors.textHigh, fontSize: 13, fontWeight: FontWeight.w700)),
            ]),
          ),
        ),
      );
}

/// What to say, when nothing has been said yet - a new example every few
/// seconds, in a pill like Home's search bar.
class _Hints extends StatefulWidget {
  const _Hints({super.key, required this.examples, this.englishOnly = false});

  final List<String> examples;
  final bool englishOnly;

  @override
  State<_Hints> createState() => _HintsState();
}

class _HintsState extends State<_Hints> {
  Timer? _timer;
  int _i = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 2800), (_) {
      if (mounted && widget.examples.isNotEmpty) setState(() => _i = (_i + 1) % widget.examples.length);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final examples = widget.examples;
    final example = examples.isEmpty ? '' : examples[_i % examples.length];
    return Column(mainAxisSize: MainAxisSize.min, children: [
      const Text('Try saying',
          style: TextStyle(color: BrokaColors.textMid, fontSize: 13, letterSpacing: 0.6)),
      const SizedBox(height: 6),
      AnimatedSwitcher(
        duration: BrokaMotion.of(context, const Duration(milliseconds: 420)),
        transitionBuilder: (c, a) => FadeTransition(
          opacity: a,
          child: ScaleTransition(scale: Tween(begin: 0.92, end: 1.0).animate(a), child: c),
        ),
        child: Container(
          key: ValueKey(example),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: BrokaColors.bgCard.withOpacity(0.86),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.45)),
            boxShadow: [BoxShadow(color: BrokaColors.neonBlue.withOpacity(0.14), blurRadius: 14)],
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.graphic_eq_rounded, size: 18, color: BrokaColors.neonCyan),
            const SizedBox(width: 8),
            Flexible(
              child: Text(example,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: BrokaColors.textHigh, fontSize: 16, fontWeight: FontWeight.w700)),
            ),
          ]),
        ),
      ),
      if (widget.englishOnly) ...[
        const SizedBox(height: 6),
        const Text('Voice is listening in English for your language',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: BrokaColors.textMid, fontSize: 11.5)),
      ],
    ]);
  }
}

/// Pause and End, each with its word under it. Pause rests the microphone and
/// keeps the screen; End closes voice mode. Neither is a telephone's.
class _Controls extends StatelessWidget {
  const _Controls({
    required this.paused,
    required this.canPause,
    required this.onPause,
    required this.onResume,
    required this.onClose,
  });

  final bool paused;
  final bool canPause;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        if (canPause) ...[
          _LabelledButton(
            icon: paused ? Icons.mic_rounded : Icons.pause_rounded,
            label: paused ? 'Resume' : 'Pause',
            tooltip: paused ? 'Resume listening' : 'Pause voice',
            lit: paused,
            onTap: paused ? onResume : onPause,
          ),
          const SizedBox(width: 56),
        ],
        _LabelledButton(
          icon: Icons.close_rounded,
          label: 'End',
          tooltip: 'End voice',
          danger: true,
          onTap: onClose,
        ),
      ]);
}

class _LabelledButton extends StatelessWidget {
  const _LabelledButton({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.onTap,
    this.lit = false,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final String tooltip;
  final VoidCallback onTap;

  /// The brand gradient, for the button that carries on (Resume).
  final bool lit;

  /// The warm edge of the one that ends something.
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final edge = danger ? BrokaColors.danger.withOpacity(0.7) : BrokaColors.border;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Tooltip(
        message: tooltip,
        child: Semantics(
          button: true,
          label: label,
          child: GestureDetector(
            onTap: onTap,
            behavior: HitTestBehavior.opaque,
            child: AnimatedContainer(
              duration: BrokaMotion.quick,
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: lit ? null : (danger ? BrokaColors.danger.withOpacity(0.14) : BrokaColors.bgCard.withOpacity(0.8)),
                gradient: lit
                    ? const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [BrokaColors.neonPurple, BrokaColors.neonBlue],
                      )
                    : null,
                border: lit ? null : Border.all(color: edge),
                boxShadow: lit
                    ? [BoxShadow(color: BrokaColors.neonBlue.withOpacity(0.45), blurRadius: 20, spreadRadius: 1)]
                    : null,
              ),
              child: Icon(icon, color: danger ? BrokaColors.danger : BrokaColors.textHigh, size: 28),
            ),
          ),
        ),
      ),
      const SizedBox(height: 7),
      Text(label, style: const TextStyle(color: BrokaColors.textHigh, fontSize: 13.5, fontWeight: FontWeight.w600)),
    ]);
  }
}

/// "Tap to show keyboard": back to typing.
class _KeyboardLink extends StatelessWidget {
  const _KeyboardLink({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: 'Type instead',
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.keyboard_rounded, size: 18, color: BrokaColors.textMid),
              SizedBox(width: 7),
              Text('Tap to show keyboard',
                  style: TextStyle(color: BrokaColors.textMid, fontSize: 13, letterSpacing: 0.3)),
            ]),
          ),
        ),
      );
}
