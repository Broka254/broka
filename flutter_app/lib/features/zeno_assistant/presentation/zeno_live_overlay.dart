// Voice mode - talking to Zeno the way one talks to Siri.
//
// Full screen, over the typed conversation rather than instead of it: every
// spoken turn goes through the screen's own send path, so it is in the
// conversation when voice mode closes, and the keyboard button is one tap
// back to typing. The session itself is ZenoVoiceController's - the same
// Deepgram session, transcript and state machine the floating voice card
// uses - so nothing about listening is written twice. This file only draws
// it:
//
//   it opens as a circle growing out of the microphone button;
//   the orb (zeno_orb.dart) shows what Zeno is doing;
//   the captions show what it heard as it hears it, then what it says;
//   an action card shows what it is doing, or asks before a call;
//   the controls: type instead, the main button (send now, interrupt Zeno,
//   try again), and close.
//
// Like the voice card, it can't outlive the tree that opened it: an open
// microphone behind a popped screen is exactly the failure brief §25 names.
//
// 2026-09-27: it is mounted once, above the Navigator, by Zeno's session
// (zeno_session_host.dart), so that opening a screen no longer ends the
// conversation: the view shrinks back into a pill that keeps listening
// ([expanded] false, the microphone still open) and grows out of it again.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../main.dart' show BrokaColors, ZoneGlowText;
import '../../../services/zeno_voice_controller.dart';
import '../../../theme/motion.dart';
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
    this.thinking = false,
    this.actionCard,
    this.burst = 0,
    this.muted = false,
    this.onToggleMute,
    this.expanded = true,
    this.origin = const Alignment(0.82, 0.9),
    this.onMinimize,
  });

  final ZenoVoiceController controller;
  final Widget child;

  /// Zeno's latest reply in this session, if any.
  final String? zenoSays;

  /// The screen is waiting on Zeno's reply.
  final bool thinking;

  /// What Zeno is doing, or asking to do.
  final Widget? actionCard;

  /// Goes up by one each time an action is taken - the orb's shockwave.
  final int burst;

  final bool muted;
  final VoidCallback? onToggleMute;
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
    if (old.expanded != widget.expanded || old.controller != widget.controller) _onController();
  }

  void _onController() {
    final open = widget.controller.isOpen && widget.expanded;
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

class _LiveView extends StatelessWidget {
  const _LiveView({required this.overlay});

  final ZenoLiveOverlay overlay;

  ZenoOrbMode _mode(VoiceSessionState s) {
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

  static String status(VoiceSessionState s, {required bool thinking, required bool hearing}) {
    if (thinking) return 'Thinking…';
    return switch (s) {
      VoiceSessionState.idle || VoiceSessionState.connecting => 'Waking up…',
      VoiceSessionState.reconnecting => 'Reconnecting…',
      VoiceSessionState.listening => hearing ? "I'm listening" : 'Listening…',
      VoiceSessionState.processing || VoiceSessionState.readyToSend => 'Got it…',
      VoiceSessionState.sendingToZeno => 'Thinking…',
      VoiceSessionState.speaking => 'Speaking',
      VoiceSessionState.error => 'Voice stopped',
    };
  }

  @override
  Widget build(BuildContext context) {
    final c = overlay.controller;
    return Material(
      type: MaterialType.transparency,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0, -0.2),
            radius: 1.1,
            // Near-opaque: the conversation underneath is kept (closing
            // voice returns to it) but not read through the captions.
            colors: [Color(0xFC140B33), Color(0xFD070B16), Color(0xFF03040A)],
            stops: [0.0, 0.55, 1.0],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(builder: (context, box) {
            // Short screens (and large text) give the captions less room;
            // the orb takes whatever is left, so nothing is ever pushed off.
            final tall = box.maxHeight >= 640;
            final captionHeight = tall ? 150.0 : (box.maxHeight * 0.2).clamp(84.0, 130.0);
            return AnimatedBuilder(
              animation: c,
              builder: (context, _) {
                final state = c.state;
                final heard = '${c.transcript.text} ${c.interim}'.trim();
                final thinking = overlay.thinking || state == VoiceSessionState.sendingToZeno;
                return Column(children: [
                  _TopBar(
                    status: status(state, thinking: overlay.thinking, hearing: heard.isNotEmpty || c.level > 0.2),
                    muted: overlay.muted,
                    onToggleMute: overlay.onToggleMute,
                    onClose: overlay.onMinimize ?? overlay.onClose,
                    minimizes: overlay.onMinimize != null,
                  ),
                  Expanded(
                    child: LayoutBuilder(builder: (context, room) {
                      final orb = math.min(room.maxWidth * 0.82, room.maxHeight * 0.96).clamp(64.0, 340.0);
                      // Sits low in its space, close to the captions it
                      // speaks through.
                      return Align(
                        alignment: const Alignment(0, 0.45),
                        child: GestureDetector(
                          onTap: switch (state) {
                            VoiceSessionState.speaking => overlay.onInterrupt,
                            VoiceSessionState.error => c.open,
                            _ => null,
                          },
                          child: ZenoOrb(mode: _mode(state), level: c.level, burst: overlay.burst, size: orb),
                        ),
                      );
                    }),
                  ),
                  SizedBox(
                    height: captionHeight,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 28),
                      child: _Captions(
                        state: state,
                        heard: heard,
                        interim: c.interim,
                        zenoSays: overlay.zenoSays,
                        thinking: thinking,
                        error: c.errorMessage,
                        errorReference: c.errorReference,
                        languageUnsupported: c.languageUnsupported,
                      ),
                    ),
                  ),
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
                  SizedBox(height: tall ? 20 : 8),
                  _Controls(
                    state: state,
                    canSend: c.hasSendableText,
                    thinking: thinking,
                    onKeyboard: overlay.onKeyboard,
                    onSend: c.submit,
                    onInterrupt: overlay.onInterrupt,
                    onRetry: c.open,
                    onClose: overlay.onClose,
                  ),
                  SizedBox(height: tall ? 18 : 8),
                ]);
              },
            );
          }),
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.status,
    required this.muted,
    required this.onClose,
    this.onToggleMute,
    this.minimizes = false,
  });

  final String status;
  final bool muted;
  final bool minimizes;
  final VoidCallback? onToggleMute;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
        child: Row(children: [
          IconButton(
            tooltip: minimizes ? 'Keep Zeno on while you browse' : 'Close voice',
            onPressed: onClose,
            icon: const Icon(Icons.keyboard_arrow_down_rounded, color: BrokaColors.textHigh, size: 30),
          ),
          Expanded(
            child: Column(children: [
              const ZoneGlowText('Zeno',
                  gradient: [BrokaColors.neonPurple, BrokaColors.neonCyan],
                  fontSize: 18,
                  maxLines: 1,
                  letterSpacing: 2.4),
              const SizedBox(height: 2),
              AnimatedSwitcher(
                duration: BrokaMotion.quick,
                child: Text(status,
                    key: ValueKey(status),
                    style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5, letterSpacing: 0.4)),
              ),
            ]),
          ),
          IconButton(
            tooltip: muted ? "Read Zeno's replies aloud" : 'Mute Zeno',
            onPressed: onToggleMute,
            icon: Icon(muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                color: muted ? BrokaColors.textMid : BrokaColors.textHigh),
          ),
        ]),
      );
}

class _Captions extends StatelessWidget {
  const _Captions({
    required this.state,
    required this.heard,
    required this.interim,
    required this.zenoSays,
    required this.thinking,
    required this.error,
    required this.errorReference,
    required this.languageUnsupported,
  });

  final VoiceSessionState state;
  final String heard;
  final String interim;
  final String? zenoSays;
  final bool thinking;
  final String? error;
  final String? errorReference;
  final bool languageUnsupported;

  @override
  Widget build(BuildContext context) {
    final Widget child;
    if (state == VoiceSessionState.error) {
      child = Column(key: const ValueKey('error'), mainAxisSize: MainAxisSize.min, children: [
        Text(error ?? "Voice isn't available right now.",
            textAlign: TextAlign.center,
            style: const TextStyle(color: BrokaColors.textHigh, fontSize: 17, height: 1.35)),
        if (errorReference != null) ...[
          const SizedBox(height: 6),
          Text(errorReference!, style: const TextStyle(color: BrokaColors.textMid, fontSize: 11)),
        ],
        const SizedBox(height: 6),
        const Text('Tap Zeno to try again', style: TextStyle(color: BrokaColors.textMid, fontSize: 12.5)),
      ]);
    } else if (state == VoiceSessionState.speaking && (zenoSays ?? '').isNotEmpty) {
      child = _Said(key: ValueKey('zeno:$zenoSays'), text: zenoSays!, zeno: true);
    } else if (heard.isNotEmpty) {
      child = _Said(key: const ValueKey('you'), text: heard, dim: thinking, interim: interim);
    } else if (!thinking && (zenoSays ?? '').isNotEmpty && state != VoiceSessionState.connecting) {
      // What Zeno last said stays up, faded, until the user speaks.
      child = _Said(key: ValueKey('last:$zenoSays'), text: zenoSays!, zeno: true, dim: true);
    } else if (thinking) {
      child = const SizedBox(key: ValueKey('thinking'));
    } else {
      child = _Hints(key: const ValueKey('hints'), englishOnly: languageUnsupported);
    }
    return AnimatedSwitcher(
      duration: BrokaMotion.of(context, const Duration(milliseconds: 320)),
      transitionBuilder: (c, a) => FadeTransition(
        opacity: a,
        child: SlideTransition(
          position: Tween(begin: const Offset(0, 0.15), end: Offset.zero).animate(a),
          child: c,
        ),
      ),
      layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.center, children: [...previous, if (current != null) current]),
      child: child,
    );
  }
}

/// A caption: the user's words (the still-being-revised tail lighter) or
/// Zeno's.
class _Said extends StatelessWidget {
  const _Said({super.key, required this.text, this.zeno = false, this.dim = false, this.interim = ''});

  final String text;
  final bool zeno;
  final bool dim;
  final String interim;

  @override
  Widget build(BuildContext context) {
    final base = TextStyle(
      color: (zeno ? BrokaColors.textHigh : Colors.white).withOpacity(dim ? 0.55 : 1),
      fontSize: zeno ? 19 : 23,
      height: 1.35,
      fontWeight: zeno ? FontWeight.w500 : FontWeight.w700,
    );
    final settled = interim.isNotEmpty && text.endsWith(interim)
        ? text.substring(0, text.length - interim.length)
        : text;
    return Text.rich(
      TextSpan(children: [
        TextSpan(text: settled, style: base),
        if (settled != text)
          TextSpan(text: interim, style: base.copyWith(color: base.color!.withOpacity(0.55))),
      ]),
      textAlign: TextAlign.center,
      maxLines: 5,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// What to say, when nothing has been said yet - a new example every few
/// seconds.
class _Hints extends StatefulWidget {
  const _Hints({super.key, this.englishOnly = false});

  final bool englishOnly;

  static const examples = [
    '"Open my inbox"',
    '"Search for a Toyota Axio"',
    '"How do I open a store?"',
    '"Find me a laptop under 50k"',
    '"Call Jane"',
    '"Tips to sell faster"',
    '"What do you think of my rating?"',
    '"Take me to Sell"',
  ];

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
      if (mounted) setState(() => _i = (_i + 1) % _Hints.examples.length);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Try saying',
            style: TextStyle(color: BrokaColors.textMid, fontSize: 13, letterSpacing: 0.6)),
        const SizedBox(height: 6),
        AnimatedSwitcher(
          duration: BrokaMotion.of(context, const Duration(milliseconds: 420)),
          transitionBuilder: (c, a) => FadeTransition(
            opacity: a,
            child: ScaleTransition(scale: Tween(begin: 0.92, end: 1.0).animate(a), child: c),
          ),
          child: Text(_Hints.examples[_i],
              key: ValueKey(_i),
              textAlign: TextAlign.center,
              style: const TextStyle(color: BrokaColors.textHigh, fontSize: 21, fontWeight: FontWeight.w700)),
        ),
        if (widget.englishOnly) ...[
          const SizedBox(height: 8),
          const Text('Voice is listening in English for your language',
              style: TextStyle(color: BrokaColors.textMid, fontSize: 11.5)),
        ],
      ]);
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.state,
    required this.canSend,
    required this.thinking,
    required this.onKeyboard,
    required this.onSend,
    required this.onInterrupt,
    required this.onRetry,
    required this.onClose,
  });

  final VoiceSessionState state;
  final bool canSend;
  final bool thinking;
  final VoidCallback onKeyboard;
  final VoidCallback onSend;
  final VoidCallback onInterrupt;
  final VoidCallback onRetry;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final (IconData icon, String label, VoidCallback? onTap) = switch (state) {
      VoiceSessionState.speaking => (Icons.stop_rounded, 'Stop Zeno', onInterrupt),
      VoiceSessionState.error => (Icons.refresh_rounded, 'Try again', onRetry),
      _ when thinking => (Icons.more_horiz_rounded, 'Zeno is thinking', null),
      _ when canSend => (Icons.arrow_upward_rounded, 'Send now', onSend),
      _ => (Icons.mic_rounded, 'Listening', null),
    };
    return Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
      _RoundButton(icon: Icons.keyboard_rounded, tooltip: 'Type instead', onTap: onKeyboard),
      _MainButton(icon: icon, label: label, onTap: onTap, live: state == VoiceSessionState.listening),
      _RoundButton(icon: Icons.close_rounded, tooltip: 'End voice', onTap: onClose),
    ]);
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.tooltip, required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: Material(
          color: BrokaColors.bgCard.withOpacity(0.8),
          shape: const CircleBorder(side: BorderSide(color: BrokaColors.border)),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox.square(
              dimension: 54,
              child: Icon(icon, color: BrokaColors.textHigh, size: 24),
            ),
          ),
        ),
      );
}

class _MainButton extends StatelessWidget {
  const _MainButton({required this.icon, required this.label, required this.onTap, required this.live});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool live;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: label,
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: BrokaMotion.quick,
            width: 76,
            height: 76,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: onTap == null && !live
                    ? [BrokaColors.bgCard, BrokaColors.bgMid]
                    : const [BrokaColors.neonPurple, BrokaColors.neonBlue],
              ),
              boxShadow: [
                BoxShadow(
                  color: BrokaColors.neonBlue.withOpacity(onTap == null && !live ? 0.1 : 0.45),
                  blurRadius: 22,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: AnimatedSwitcher(
              duration: BrokaMotion.quick,
              transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
              child: Icon(icon, key: ValueKey(icon), color: Colors.white, size: 32),
            ),
          ),
        ),
      );
}
