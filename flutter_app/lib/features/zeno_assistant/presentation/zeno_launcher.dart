// Zeno's orb, floating at the edge of every screen (2026-10-09).
//
// Voice mode could be opened from two places: the Zeno tab's microphone,
// and holding the Zeno tab on Home - which nobody finds by accident. A
// phone's assistant is a button press away whatever is on screen, so Zeno
// is too: a small orb on the edge of every signed-in screen. Tap it and
// voice mode grows out of it; hold it for the typed conversation; drag it
// up, down or to the other side, and it stays where it was put.
//
// It keeps out of the way where it would be in it: on the splash and
// sign-in, in a call, over a camera, over the Zeno tab and the Buying
// Agent (which have their own microphones), over dialogs and sheets, while
// the keyboard is up, and while Zeno's session is already on screen. A
// screen can keep it off with ZenoLauncher.hideOver(context). Settings can
// turn it off altogether.
//
// Drawn by the session host (zeno_session_host.dart), above the Navigator.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../main.dart' show BrokaColors;
import '../../../services/api_service.dart';
import '../../../theme/motion.dart';
import '../../../widgets/zeno_avatar.dart';
import '../zeno_session.dart';
import '../zeno_tour.dart';

/// Whether the orb is on, and where the user left it.
class ZenoLauncherPrefs {
  ZenoLauncherPrefs._();

  /// Settings' switch, live.
  static final ValueNotifier<bool> enabled = ValueNotifier(true);

  /// How far down the screen (0..1), and which side.
  static double? dy;
  static bool left = false;

  static bool _loaded = false;
  static const _kOn = 'zeno_launcher_on';
  static const _kDy = 'zeno_launcher_dy';
  static const _kLeft = 'zeno_launcher_left';

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      enabled.value = prefs.getBool(_kOn) ?? true;
      dy = prefs.getDouble(_kDy);
      left = prefs.getBool(_kLeft) ?? false;
    } catch (_) {}
  }

  static Future<void> setEnabled(bool on) async {
    enabled.value = on;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kOn, on);
    } catch (_) {}
  }

  static Future<void> savePosition(double fraction, bool onLeft) async {
    dy = fraction;
    left = onLeft;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kDy, fraction);
      await prefs.setBool(_kLeft, onLeft);
    } catch (_) {}
  }

  @visibleForTesting
  static void reset() {
    _loaded = false;
    enabled.value = true;
    dy = null;
    left = false;
  }
}

class ZenoLauncher extends StatefulWidget {
  const ZenoLauncher({super.key, required this.session});

  final ZenoSession session;

  /// Screens it never floats over, by route name.
  static const hiddenOn = {
    '/splash',
    '/auth',
    '/voip-call',
    '/selfie',
    '/zeno',
    '/buying-agent',
  };

  static final Expando<bool> _optedOut = Expando<bool>('zeno-launcher-off');

  /// Keeps the orb off the screen [context] is on - a camera, a photo
  /// shown full screen.
  static void hideOver(BuildContext context) {
    final route = ModalRoute.of(context);
    if (route != null) _optedOut[route] = true;
  }

  /// Where it may float, given the screen in front.
  static bool allowedOver(Route<dynamic>? top) {
    if (top == null || top is PopupRoute) return false;
    if (hiddenOn.contains(top.settings.name)) return false;
    return _optedOut[top] != true;
  }

  static const double size = 62;

  @override
  State<ZenoLauncher> createState() => _ZenoLauncherState();
}

class _ZenoLauncherState extends State<ZenoLauncher> with SingleTickerProviderStateMixin {
  // Made in initState, not lazily: a lazy one first touched in dispose
  // asks a deactivated tree for its TickerMode.
  late final AnimationController _press;

  /// Where it is while a finger moves it, in pixels.
  Offset? _drag;

  ZenoSession get _s => widget.session;

  @override
  void initState() {
    super.initState();
    _press = AnimationController(vsync: this, duration: BrokaMotion.instant);
    ZenoLauncherPrefs.load().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _press.dispose();
    super.dispose();
  }

  bool _shown(BuildContext context) {
    if (ApiService.currentUserId == null || !ZenoLauncherPrefs.enabled.value) return false;
    if (_s.isActive || _s.tour.phase == ZenoTourPhase.welcome) return false;
    if (MediaQuery.viewInsetsOf(context).bottom > 0) return false;
    return ZenoLauncher.allowedOver(_s.routes.top);
  }

  /// The orb's top-left, in pixels, within [box].
  Offset _place(Size box, EdgeInsets pad) {
    final top = pad.top + 76;
    final bottom = box.height - pad.bottom - 150;
    final fraction = ZenoLauncherPrefs.dy ?? 0.66;
    final y = (box.height * fraction).clamp(top, math.max(top, bottom)).toDouble();
    final x = ZenoLauncherPrefs.left ? 10.0 : box.width - ZenoLauncher.size - 10;
    return Offset(x, y);
  }

  void _talk(Size box, Offset at) {
    HapticFeedback.mediumImpact();
    final c = at + const Offset(ZenoLauncher.size / 2, ZenoLauncher.size / 2);
    _s.start(from: Alignment(c.dx / box.width * 2 - 1, c.dy / box.height * 2 - 1));
  }

  void _openChat() {
    HapticFeedback.selectionClick();
    _s.routes.navigator?.pushNamed('/zeno');
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_s, _s.tour, _s.screenChanged, ZenoLauncherPrefs.enabled]),
      builder: (context, _) {
        final mq = MediaQuery.of(context);
        final box = mq.size;
        final shown = _shown(context);
        final at = _drag ?? _place(box, mq.padding);
        // During the tour's "I'm everywhere" step, the orb shows itself off.
        final spotlight = _s.tour.step?.id == 'anywhere';
        return AnimatedPositioned(
          duration: _drag != null ? Duration.zero : BrokaMotion.of(context, BrokaMotion.standard),
          curve: BrokaMotion.accent,
          left: at.dx,
          top: at.dy,
          // Built only while it shows: hidden, nothing of it turns or ticks.
          child: AnimatedSwitcher(
            duration: BrokaMotion.of(context, BrokaMotion.quick),
            switchInCurve: BrokaMotion.accent,
            switchOutCurve: BrokaMotion.exit,
            transitionBuilder: (child, a) => FadeTransition(
              opacity: a,
              child: ScaleTransition(scale: Tween(begin: 0.4, end: 1.0).animate(a), child: child),
            ),
            child: !shown
                ? const SizedBox.square(key: ValueKey('off'), dimension: ZenoLauncher.size)
                : Semantics(
                  key: const ValueKey('on'),
                  button: true,
                  label: 'Talk to Zeno',
                  hint: 'Hold to type to Zeno instead',
                  child: Tooltip(
                    message: 'Talk to Zeno',
                    child: GestureDetector(
                      key: const Key('zeno-launcher'),
                      behavior: HitTestBehavior.opaque,
                      onTap: () => _talk(box, at),
                      onLongPress: _openChat,
                      onTapDown: (_) => _press.forward(),
                      onTapUp: (_) => _press.reverse(),
                      onTapCancel: () => _press.reverse(),
                      onPanStart: (_) => setState(() => _drag = at),
                      onPanUpdate: (d) => setState(() {
                        final p = (_drag ?? at) + d.delta;
                        _drag = Offset(
                          p.dx.clamp(0.0, box.width - ZenoLauncher.size),
                          p.dy.clamp(mq.padding.top, box.height - ZenoLauncher.size - mq.padding.bottom),
                        );
                      }),
                      onPanEnd: (_) {
                        final p = _drag ?? at;
                        final onLeft = p.dx + ZenoLauncher.size / 2 < box.width / 2;
                        ZenoLauncherPrefs.savePosition((p.dy / box.height).clamp(0.0, 1.0), onLeft);
                        setState(() => _drag = null);
                      },
                      child: AnimatedBuilder(
                        animation: _press,
                        builder: (_, child) => Transform.scale(scale: 1 - 0.08 * _press.value, child: child),
                        child: _LauncherOrb(spotlight: spotlight),
                      ),
                    ),
                  ),
                ),
          ),
        );
      },
    );
  }
}

/// Zeno in a turning ring of its colours, a counter-turning dashed orbit,
/// a soft halo that breathes, and a small microphone: tap to talk.
class _LauncherOrb extends StatefulWidget {
  const _LauncherOrb({required this.spotlight});

  final bool spotlight;

  @override
  State<_LauncherOrb> createState() => _LauncherOrbState();
}

class _LauncherOrbState extends State<_LauncherOrb> with SingleTickerProviderStateMixin {
  late final AnimationController _spin =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 5200));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (BrokaMotion.reduced(context)) {
      _spin.stop();
    } else if (!_spin.isAnimating) {
      _spin.repeat();
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: ZenoLauncher.size,
        child: Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [
          Positioned.fill(
            child: RepaintBoundary(
              child: CustomPaint(painter: _LauncherPainter(_spin, spotlight: widget.spotlight)),
            ),
          ),
          const ZenoAvatar(size: 40),
          Positioned(
            right: 2,
            bottom: 2,
            child: Container(
              width: 19,
              height: 19,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(colors: [BrokaColors.neonPurple, BrokaColors.neonCyan]),
                border: Border.all(color: BrokaColors.bg, width: 1.6),
                boxShadow: [BoxShadow(color: BrokaColors.neonCyan.withOpacity(0.5), blurRadius: 6)],
              ),
              child: const Icon(Icons.mic_rounded, size: 11, color: Colors.white),
            ),
          ),
        ]),
      );
}

class _LauncherPainter extends CustomPainter {
  _LauncherPainter(this.a, {required this.spotlight}) : super(repaint: a);

  final Animation<double> a;
  final bool spotlight;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final t = a.value;
    final r = size.shortestSide / 2 - 3;
    final breathe = 0.5 + 0.5 * math.sin(t * 2 * math.pi * 2);

    // Halo.
    canvas.drawCircle(
      c,
      r + 8,
      Paint()
        ..shader = RadialGradient(colors: [
          BrokaColors.neonPurple.withOpacity(0.30 + 0.18 * breathe),
          BrokaColors.neonBlue.withOpacity(0.10),
          Colors.transparent,
        ], stops: const [0.45, 0.75, 1.0])
            .createShader(Rect.fromCircle(center: c, radius: r + 8)),
    );

    // Look-here ripples, for the tour.
    if (spotlight) {
      for (var i = 0; i < 3; i++) {
        final p = (t * 4 + i / 3) % 1.0;
        canvas.drawCircle(
          c,
          r + p * 34,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = BrokaColors.neonCyan.withOpacity((1 - p) * 0.7),
        );
      }
    }

    // A glass disc for Zeno to sit on.
    canvas.drawCircle(c, r, Paint()..color = const Color(0xE60B1022));

    // The turning ring.
    final rect = Rect.fromCircle(center: c, radius: r);
    final start = t * 2 * math.pi;
    canvas.drawArc(
      rect,
      start,
      math.pi * 1.4,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round
        ..shader = SweepGradient(
          colors: [
            BrokaColors.neonPurple.withOpacity(0),
            BrokaColors.neonPurple,
            BrokaColors.neonCyan,
          ],
          stops: const [0.0, 0.45, 0.7],
          transform: GradientRotation(start),
        ).createShader(rect),
    );
    final head = c + Offset(math.cos(start + math.pi * 1.4), math.sin(start + math.pi * 1.4)) * r;
    canvas.drawCircle(head, 2.2, Paint()..color = Colors.white);

    // A dashed orbit turning the other way.
    final dash = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = BrokaColors.neonCyan.withOpacity(0.35);
    const n = 24;
    final back = -t * 2 * math.pi * 0.5;
    for (var k = 0; k < n; k += 2) {
      canvas.drawArc(Rect.fromCircle(center: c, radius: r + 4.5), back + k * 2 * math.pi / n,
          math.pi / n, false, dash);
    }
  }

  @override
  bool shouldRepaint(_LauncherPainter old) => old.a != a || old.spotlight != spotlight;
}
