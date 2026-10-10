// Where Zeno's session (zeno_session.dart) shows: above every screen.
//
// Mounted by MaterialApp.builder around the Navigator, so it outlives any
// one route: the full-screen voice view, and when Zeno has opened a screen,
// a pill over it that keeps listening - its orb, what it hears and says, a
// button to type instead, and one to end it. Above the pill, anything that
// needs the user: a call to confirm, a person to pick, a guide's steps.
//
// It has an Overlay of its own: it sits outside the Navigator's, and
// tooltips and text fields need one.
//
// 2026-10-09: also Zeno's orb at the edge of every screen, the way into
// voice from anywhere (zeno_launcher.dart), and Zeno's tour of BROKA for a
// new account (zeno_tour_layer.dart).
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../main.dart' show BrokaColors;
import '../../../services/zeno_voice_controller.dart';
import '../../../theme/motion.dart';
import '../../buy_agent/presentation/widgets/agent_hud.dart' show AgentWaves;
import '../domain/zeno_action.dart';
import '../zeno_session.dart';
import '../zeno_tour.dart';
import 'zeno_action_card.dart';
import 'zeno_launcher.dart';
import 'zeno_live_overlay.dart';
import 'zeno_orb.dart';
import 'zeno_tour_layer.dart';

class ZenoSessionHost extends StatefulWidget {
  const ZenoSessionHost({super.key, required this.session, required this.child});

  final ZenoSession session;

  /// The app's Navigator.
  final Widget child;

  @override
  State<ZenoSessionHost> createState() => _ZenoSessionHostState();
}

class _ZenoSessionHostState extends State<ZenoSessionHost> with WidgetsBindingObserver {
  late final OverlayEntry _layer = OverlayEntry(builder: (_) => _SessionLayer(session: widget.session));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Nothing listens from the background. Not on `inactive`: that is also
    // the microphone permission dialog, and the notification shade.
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      widget.session.end();
      // Nothing more said or opened while nobody is looking; Next goes on.
      widget.session.tour.hold();
    }
  }

  /// Back, with nothing under it to go back to (Home - where the tour
  /// starts): it closes the tour rather than leave the app from under it.
  /// The Navigator is asked first, so on any other screen back is back.
  @override
  Future<bool> didPopRoute() async {
    final tour = widget.session.tour;
    if (tour.phase == ZenoTourPhase.welcome) {
      tour.decline();
      return true;
    }
    if (tour.active) {
      tour.end();
      return true;
    }
    return false;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.session.stopForDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ZenoSessionScope(
        session: widget.session,
        child: Stack(fit: StackFit.expand, children: [
          widget.child,
          // Where nothing of the session is drawn, touches go through to
          // the screen underneath.
          Overlay(initialEntries: [_layer]),
        ]),
      );
}

class _SessionLayer extends StatelessWidget {
  const _SessionLayer({required this.session});

  final ZenoSession session;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: session,
        builder: (context, _) {
          final voice = session.voice;
          return Stack(fit: StackFit.expand, children: [
            if (voice != null)
              ZenoLiveOverlay(
                controller: voice,
                expanded: session.expanded,
                origin: session.origin,
                zenoSays: session.reply,
                thinking: session.thinking,
                actionCard: session.expanded ? _card(context, large: true) : null,
                burst: session.burst,
                muted: session.muted,
                onToggleMute: session.toggleMute,
                onClose: session.end,
                onMinimize: session.dock,
                onKeyboard: session.typeInstead,
                onInterrupt: session.interrupt,
                child: const SizedBox.shrink(),
              ),
            _Dock(session: session, card: session.docked ? _card(context, large: false) : null),
            ZenoLauncher(session: session),
            ZenoTourLayer(session: session),
          ]);
        },
      );

  /// What the session has to show about its action, if anything.
  Widget? _card(BuildContext context, {required bool large}) {
    final action = session.action;
    final phase = session.phase;
    if (action == null || phase == null || phase == ZenoActionPhase.dismissed) return null;
    final guide = action.type == ZenoActionType.guide;
    final asks = action.type == ZenoActionType.call || action.choices.isNotEmpty;
    // Docked, a screen that opened is its own confirmation; only what still
    // needs the user stays over it.
    if (!large && !guide && !(asks && phase == ZenoActionPhase.pending)) return null;
    final height = MediaQuery.sizeOf(context).height;
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: height * (large ? 0.34 : 0.46)),
      child: ZenoActionCard(
        key: ObjectKey(action),
        action: action,
        phase: phase,
        large: large && height >= 700 && !guide,
        onConfirm: action.type == ZenoActionType.call ? session.confirmCall : session.runAction,
        onDismiss: session.dismissAction,
        onChoose: session.choose,
        onStep: session.openStep,
        visited: session.guideVisited,
        folded: !large && session.guideFolded,
        onFold: large ? null : session.foldGuide,
      ),
    );
  }
}

/// The session docked: the pill, and above it (below it, when the pill is
/// at the top) whatever still needs the user.
class _Dock extends StatefulWidget {
  const _Dock({required this.session, this.card});

  final ZenoSession session;
  final Widget? card;

  @override
  State<_Dock> createState() => _DockState();
}

class _DockState extends State<_Dock> {
  double _drag = 0;

  // A long reply shows above the pill until it is put away; the pill has
  // room for a line.
  String? _putAway;

  ZenoSession get _s => widget.session;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final top = _s.pillAtTop;
    final keyboard = mq.viewInsets.bottom;
    // Clear of a bottom navigation bar, or of the keyboard when it is up.
    final bottom = keyboard > 0 ? keyboard + 10 : mq.padding.bottom + 78;
    final reply = _s.reply ?? '';
    final showReply = widget.card == null && !_s.thinking && reply.length > 70 && reply != _putAway;
    final extra = widget.card ??
        (showReply
            ? _ReplyBubble(key: ValueKey(reply), text: reply, onClose: () => setState(() => _putAway = reply))
            : null);
    final shown = _s.docked;

    final column = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (!top) _Swap(child: extra),
      if (!top && extra != null) const SizedBox(height: 8),
      GestureDetector(
        onVerticalDragUpdate: (d) => setState(() => _drag += d.delta.dy),
        onVerticalDragEnd: (d) {
          final v = d.primaryVelocity ?? 0;
          if (_drag < -60 || v < -600) _s.movePill(top: true);
          if (_drag > 60 || v > 600) _s.movePill(top: false);
          setState(() => _drag = 0);
        },
        child: Transform.translate(
          offset: Offset(0, _drag.clamp(-120.0, 120.0)),
          // What is shown above says what Zeno said; the pill needn't.
          child: _Pill(session: _s, quiet: extra != null),
        ),
      ),
      if (top && extra != null) const SizedBox(height: 8),
      if (top) _Swap(child: extra),
    ]);

    return AnimatedPositioned(
      duration: BrokaMotion.of(context, BrokaMotion.standard),
      curve: BrokaMotion.enter,
      left: 12,
      right: 12,
      // At the top, under a screen's app bar rather than over its title
      // and back button.
      top: top ? mq.padding.top + kToolbarHeight + 6 : null,
      bottom: top ? null : bottom,
      child: IgnorePointer(
        ignoring: !shown,
        child: AnimatedSwitcher(
          duration: BrokaMotion.of(context, const Duration(milliseconds: 420)),
          switchInCurve: Curves.easeOutBack,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (c, a) => FadeTransition(
            opacity: a,
            child: ScaleTransition(
              scale: Tween(begin: 0.7, end: 1.0).animate(a),
              alignment: top ? Alignment.topCenter : Alignment.bottomCenter,
              child: c,
            ),
          ),
          child: shown
              ? Align(
                  key: const ValueKey('dock'),
                  alignment: top ? Alignment.topCenter : Alignment.bottomCenter,
                  heightFactor: 1,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 440),
                    // Over a screen, outside its Scaffold: text and ink need
                    // a Material of their own.
                    child: Material(type: MaterialType.transparency, child: column),
                  ),
                )
              : const SizedBox.shrink(key: ValueKey('none')),
        ),
      ),
    );
  }
}

class _Swap extends StatelessWidget {
  const _Swap({this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
        duration: BrokaMotion.of(context, BrokaMotion.standard),
        transitionBuilder: (c, a) => FadeTransition(
          opacity: a,
          child: SizeTransition(sizeFactor: a, axisAlignment: -1, child: c),
        ),
        child: child ?? const SizedBox(key: ValueKey('nothing'), width: double.infinity),
      );
}

class _ReplyBubble extends StatelessWidget {
  const _ReplyBubble({super.key, required this.text, required this.onClose});

  final String text;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: Container(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.3),
          padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            color: BrokaColors.bgCard.withOpacity(0.96),
            border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.45)),
            boxShadow: [BoxShadow(color: BrokaColors.neonBlue.withOpacity(0.2), blurRadius: 16)],
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: SingleChildScrollView(
                child: Text(text,
                    style: const TextStyle(color: BrokaColors.textHigh, fontSize: 14, height: 1.4)),
              ),
            ),
            IconButton(
              tooltip: 'Hide',
              visualDensity: VisualDensity.compact,
              onPressed: onClose,
              icon: const Icon(Icons.close_rounded, size: 18, color: BrokaColors.textMid),
            ),
          ]),
        ),
      );
}

/// The docked session: Zeno's orb, a line of what is happening, and two
/// buttons.
class _Pill extends StatefulWidget {
  const _Pill({required this.session, this.quiet = false});

  final ZenoSession session;

  /// Zeno's reply is showing above: say something else.
  final bool quiet;

  @override
  State<_Pill> createState() => _PillState();
}

class _PillState extends State<_Pill> with SingleTickerProviderStateMixin {
  late final AnimationController _spin =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2600));
  final _text = TextEditingController();
  final _focus = FocusNode();

  ZenoSession get _s => widget.session;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_syncSpin);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncSpin();
  }

  /// The ring turns while Zeno listens or works; still when paused, and
  /// under reduced motion.
  void _syncSpin() {
    if (!mounted) return;
    final live = _s.listening || _s.thinking;
    if (live && !BrokaMotion.reduced(context)) {
      if (!_spin.isAnimating) _spin.repeat();
    } else if (_spin.isAnimating) {
      _spin.stop();
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(_syncSpin);
    _spin.dispose();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _text.text.trim();
    if (text.isEmpty) return;
    _text.clear();
    _s.send(text);
  }

  static ZenoOrbMode _mode(ZenoSession s, VoiceSessionState? state) {
    if (s.thinking) return ZenoOrbMode.thinking;
    return switch (state) {
      null || VoiceSessionState.idle => ZenoOrbMode.waking,
      VoiceSessionState.connecting || VoiceSessionState.reconnecting => ZenoOrbMode.waking,
      VoiceSessionState.listening || VoiceSessionState.processing || VoiceSessionState.readyToSend =>
        ZenoOrbMode.listening,
      VoiceSessionState.sendingToZeno => ZenoOrbMode.thinking,
      VoiceSessionState.speaking => ZenoOrbMode.speaking,
      VoiceSessionState.error => ZenoOrbMode.error,
    };
  }

  @override
  Widget build(BuildContext context) {
    final voice = _s.voice;
    return AnimatedBuilder(
      animation: Listenable.merge([_s, if (voice != null) voice]),
      builder: (context, _) {
        final state = _s.listening ? voice?.state : null;
        final heard = voice == null ? '' : '${voice.transcript.text} ${voice.interim}'.trim();
        final (status, line) = _words(state, heard);
        final level = _s.listening ? (voice?.level ?? 0) : 0.0;
        return Semantics(
          container: true,
          label: 'Zeno',
          child: Material(
            color: Colors.transparent,
            child: AnimatedBuilder(
              animation: _spin,
              builder: (context, child) => CustomPaint(
                painter: _RingPainter(turn: _spin.value, level: level, live: _s.listening || _s.thinking),
                child: child,
              ),
              child: Container(
                height: 62,
                margin: const EdgeInsets.all(2),
                padding: const EdgeInsets.only(left: 6, right: 4),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(31),
                  color: const Color(0xF20B1022),
                  boxShadow: [
                    BoxShadow(
                      color: BrokaColors.neonBlue.withOpacity(0.18 + 0.3 * level),
                      blurRadius: 18 + 18 * level,
                    ),
                  ],
                ),
                child: Row(children: [
                  Tooltip(
                    message: 'Open Zeno',
                    child: GestureDetector(
                      onTap: () => _s.expand(),
                      child: Opacity(
                        opacity: _s.listening || _s.thinking || _s.typing ? 1 : 0.6,
                        child: ZenoOrb(mode: _mode(_s, state), level: level, burst: _s.burst, size: 50, face: true),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _s.typing
                        ? TextField(
                            key: const Key('zeno-pill-field'),
                            controller: _text,
                            focusNode: _focus,
                            autofocus: true,
                            textInputAction: TextInputAction.send,
                            onSubmitted: (_) => _submit(),
                            style: const TextStyle(color: BrokaColors.textHigh, fontSize: 14.5),
                            cursorColor: BrokaColors.neonCyan,
                            decoration: const InputDecoration(
                              hintText: 'Ask Zeno…',
                              hintStyle: TextStyle(color: BrokaColors.textLow),
                              filled: false,
                              isDense: true,
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                            ),
                          )
                        : GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: () => _s.listening ? _s.expand() : _s.resumeMic(),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(children: [
                                  // Zeno's thinking waves, as in every Zeno chat.
                                  if (_s.thinking) ...[
                                    const AgentWaves(width: 30, height: 12),
                                    const SizedBox(width: 6),
                                  ],
                                  Flexible(
                                    child: Text(status,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: _s.listening || _s.thinking ? BrokaColors.neonCyan : BrokaColors.textMid,
                                          fontSize: 11,
                                          fontWeight: FontWeight.w700,
                                          letterSpacing: 0.6,
                                        )),
                                  ),
                                ]),
                                const SizedBox(height: 2),
                                AnimatedSwitcher(
                                  duration: BrokaMotion.of(context, BrokaMotion.quick),
                                  layoutBuilder: (current, previous) => Stack(
                                      alignment: Alignment.centerLeft,
                                      children: [...previous, if (current != null) current]),
                                  child: Text(line,
                                      key: ValueKey(line),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                          color: BrokaColors.textHigh, fontSize: 14, fontWeight: FontWeight.w600)),
                                ),
                              ],
                            ),
                          ),
                  ),
                  if (_s.typing)
                    _PillButton(
                      icon: Icons.arrow_upward_rounded,
                      tooltip: 'Send to Zeno',
                      filled: true,
                      onTap: _submit,
                    ),
                  _PillButton(
                    icon: _s.typing || !_s.listening ? Icons.mic_rounded : Icons.keyboard_rounded,
                    tooltip: _s.typing || !_s.listening ? 'Talk to Zeno' : 'Type to Zeno',
                    onTap: () => _s.typing || !_s.listening ? _s.resumeMic() : _s.typeInstead(),
                  ),
                  _PillButton(icon: Icons.close_rounded, tooltip: 'End Zeno', onTap: _s.end),
                ]),
              ),
            ),
          ),
        );
      },
    );
  }

  /// The pill's two lines: what state it is in, and the words - the
  /// user's as they are heard, else Zeno's.
  (String, String) _words(VoiceSessionState? state, String heard) {
    final reply = widget.quiet ? '' : _s.reply ?? '';
    final said = reply.isNotEmpty ? reply : (widget.quiet ? "Go on - I'm listening" : 'Say "open my inbox"');
    if (_s.thinking) return ('THINKING', _s.heard ?? '…');
    if (!_s.listening) {
      return (_s.typing ? 'TYPING' : 'TAP TO TALK', reply.isNotEmpty ? reply : 'Zeno is here when you need it');
    }
    return switch (state) {
      VoiceSessionState.connecting || VoiceSessionState.reconnecting => ('WAKING UP', said),
      VoiceSessionState.speaking => ('SPEAKING', said),
      VoiceSessionState.error => ('VOICE STOPPED', 'Tap to try again'),
      _ when heard.isNotEmpty => ('HEARING YOU', heard),
      _ => ('LISTENING', said),
    };
  }
}

class _PillButton extends StatelessWidget {
  const _PillButton({required this.icon, required this.tooltip, required this.onTap, this.filled = false});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: InkResponse(
          onTap: onTap,
          radius: 24,
          child: Container(
            width: 40,
            height: 40,
            margin: const EdgeInsets.symmetric(horizontal: 1),
            decoration: filled
                ? const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(colors: [BrokaColors.neonPurple, BrokaColors.neonBlue]),
                  )
                : null,
            child: Icon(icon, size: 21, color: filled ? Colors.white : BrokaColors.textHigh),
          ),
        ),
      );
}

/// A ring of Zeno's colours turning around the pill, brighter with the
/// voice it hears.
class _RingPainter extends CustomPainter {
  _RingPainter({required this.turn, required this.level, required this.live});

  final double turn;
  final double level;
  final bool live;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect.deflate(1), Radius.circular(size.height / 2));
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6 + 1.4 * level;
    if (!live) {
      paint.color = BrokaColors.border;
    } else {
      paint.shader = SweepGradient(
        colors: const [
          BrokaColors.neonPurple,
          BrokaColors.neonCyan,
          BrokaColors.neonBlue,
          Color(0x00000000),
          BrokaColors.neonPurple,
        ],
        stops: const [0.0, 0.3, 0.55, 0.8, 1.0],
        transform: GradientRotation(turn * 2 * math.pi),
      ).createShader(rect);
    }
    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.turn != turn || old.level != level || old.live != live;
}
