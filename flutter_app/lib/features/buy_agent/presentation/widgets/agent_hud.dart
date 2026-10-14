// BROKA - the Buying Agent's HUD (2026-10-09).
//
// The motion pass (agent_motion.dart) made the agent's work visible. This
// one is about how it feels to be in the room with it. Everything here is
// drawn - no images, no shaders compiled at run time - in the brand's three
// colours:
//
//   AgentHoloBorder     a gradient edge that turns while something is live.
//   AgentThinkingWave   Zeno thinking: interfering waves, not three dots -
//                       on every Zeno screen (2026-10-10), not just this one.
//   AgentWaves          the waves alone, for a space a capsule won't fit.
//   AgentLockOn         targeting brackets closing on a result.
//   AgentHudTag         a small labelled tag with a live dot.
//
// 2026-10-10: the holographic room (an aurora over a perspective grid floor,
// a scan line, a beam under the header) went. It made the Buying Agent look
// like a different app from Home, and with the reactor core over it there
// was too much moving for anything to feel premium; the agent now sits on
// Home's constellation like every other screen.
//
// Like the motion pass: each honours reduce-motion (the layout is the same,
// nothing moves), loops drive painters from their controllers rather than
// rebuilding, and each painter sits behind a RepaintBoundary.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../main.dart' show BrokaColors;
import '../../../../theme/motion.dart';
import '../../../../widgets/zeno_avatar.dart';

const _violet = BrokaColors.neonPurple;
const _blue = BrokaColors.neonBlue;
const _cyan = BrokaColors.neonCyan;

bool _still(BuildContext context) => BrokaMotion.reduced(context);

void _loop(AnimationController c, BuildContext context) {
  if (_still(context)) {
    if (c.isAnimating) c.stop();
  } else if (!c.isAnimating) {
    c.repeat();
  }
}

// ── AgentHoloBorder ──────────────────────────────────────────────────────────

/// A gradient edge around [child]: still, or turning while [live].
class AgentHoloBorder extends StatefulWidget {
  const AgentHoloBorder({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(24)),
    this.live = false,
    this.width = 1.4,
    this.glow = 0.25,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final bool live;
  final double width;

  /// How strongly the edge glows, 0..1.
  final double glow;

  @override
  State<AgentHoloBorder> createState() => _AgentHoloBorderState();
}

class _AgentHoloBorderState extends State<AgentHoloBorder> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 3600));

  void _sync() {
    if (widget.live && !_still(context)) {
      if (!_c.isAnimating) _c.repeat();
    } else if (_c.isAnimating) {
      _c.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(AgentHoloBorder old) {
    super.didUpdateWidget(old);
    _sync();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CustomPaint(
        // No width, no edge (a zero-width stroke would still be a hairline).
        foregroundPainter: widget.width <= 0
            ? null
            : _HoloEdgePainter(_c, widget.borderRadius, width: widget.width, glow: widget.glow, live: widget.live),
        child: widget.child,
      );
}

class _HoloEdgePainter extends CustomPainter {
  _HoloEdgePainter(this.a, this.radius, {required this.width, required this.glow, required this.live})
      : super(repaint: a);
  final Animation<double> a;
  final BorderRadius radius;
  final double width;
  final double glow;
  final bool live;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = radius.toRRect(rect).deflate(width / 2);
    final turn = GradientRotation(a.value * 2 * math.pi);
    final shader = SweepGradient(
      colors: const [_violet, _blue, _cyan, _violet],
      stops: const [0.0, 0.35, 0.65, 1.0],
      transform: turn,
    ).createShader(rect);
    if (glow > 0) {
      canvas.drawRRect(
        rrect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width * 4
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, 6 * glow + (live ? 2 : 0))
          ..shader = SweepGradient(
            colors: [
              _violet.withOpacity(glow),
              _blue.withOpacity(glow),
              _cyan.withOpacity(glow),
              _violet.withOpacity(glow),
            ],
            stops: const [0.0, 0.35, 0.65, 1.0],
            transform: turn,
          ).createShader(rect),
      );
    }
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = width
        ..shader = shader,
    );
  }

  @override
  bool shouldRepaint(_HoloEdgePainter old) =>
      old.a != a || old.radius != radius || old.width != width || old.glow != glow || old.live != live;
}

// ── AgentThinkingWave ────────────────────────────────────────────────────────

/// Zeno thinking: three waves of its colours, moving through each other,
/// in a glass capsule with what it is doing written beside them.
///
/// 2026-10-10: the one "Zeno is working on it" on every Zeno screen - the
/// assistant, voice mode, the negotiation room, the sell wizard's helpers,
/// Zeno's introduction - where three bouncing dots used to stand in for it.
/// With [avatar], Zeno's face leads it, as it leads Zeno's bubbles.
class AgentThinkingWave extends StatelessWidget {
  const AgentThinkingWave({
    super.key,
    this.label = 'Zeno is thinking',
    this.avatar = false,
    this.padding = const EdgeInsets.fromLTRB(16, 4, 16, 6),
    this.alignment = Alignment.centerLeft,
  });

  final String label;
  final bool avatar;
  final EdgeInsetsGeometry padding;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    final capsule = AgentHoloBorder(
      live: true,
      borderRadius: BorderRadius.circular(20),
      glow: 0.18,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 9, 14, 9),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: BrokaColors.bgCard.withOpacity(0.88),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const AgentWaves(),
          const SizedBox(width: 10),
          Flexible(
            child: Text(label.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: _cyan, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1.5)),
          ),
        ]),
      ),
    );
    return Semantics(
      liveRegion: true,
      label: label,
      excludeSemantics: true,
      child: Padding(
        padding: padding,
        child: Align(
          alignment: alignment,
          child: avatar
              ? Row(mainAxisSize: MainAxisSize.min, children: [
                  const ZenoAvatar(size: 28),
                  const SizedBox(width: 8),
                  Flexible(child: capsule),
                ])
              : capsule,
        ),
      ),
    );
  }
}

/// The thinking waves on their own: for a line of text a capsule won't fit
/// in - Zeno's pill, a status under a title.
class AgentWaves extends StatefulWidget {
  const AgentWaves({super.key, this.width = 64, this.height = 22});

  final double width;
  final double height;

  @override
  State<AgentWaves> createState() => _AgentWavesState();
}

class _AgentWavesState extends State<AgentWaves> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loop(_c, context);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        width: widget.width,
        height: widget.height,
        child: RepaintBoundary(child: CustomPaint(painter: _WavePainter(_c))),
      );
}

class _WavePainter extends CustomPainter {
  _WavePainter(this.a) : super(repaint: a);
  final Animation<double> a;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    const colors = [_violet, _blue, _cyan];
    for (var k = 0; k < 3; k++) {
      final path = Path();
      for (var i = 0; i <= 32; i++) {
        final x = size.width * i / 32;
        final env = math.sin(math.pi * i / 32);
        final y = mid +
            math.sin((i / 32) * 2 * math.pi * (1.5 + k * 0.5) + a.value * 2 * math.pi * (k + 1) + k) *
                mid *
                0.8 *
                env;
        i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
      }
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..strokeCap = StrokeCap.round
          ..color = colors[k].withOpacity(0.9),
      );
    }
  }

  @override
  bool shouldRepaint(_WavePainter old) => old.a != a;
}

// ── AgentLockOn ──────────────────────────────────────────────────────────────

/// Targeting brackets closing in on [child]'s corners - a result locked
/// on - in [tone]. Plays once when [play]; otherwise they are simply there.
class AgentLockOn extends StatefulWidget {
  const AgentLockOn({super.key, required this.child, required this.tone, this.play = false, this.radius = 14});

  final Widget child;
  final Color tone;
  final bool play;
  final double radius;

  @override
  State<AgentLockOn> createState() => _AgentLockOnState();
}

class _AgentLockOnState extends State<AgentLockOn> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_c.isAnimating || _c.isCompleted) return;
    if (!widget.play || _still(context)) {
      _c.value = 1;
    } else {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CustomPaint(
        foregroundPainter: _LockOnPainter(_c, widget.tone, widget.radius),
        child: widget.child,
      );
}

class _LockOnPainter extends CustomPainter {
  _LockOnPainter(this.a, this.tone, this.radius) : super(repaint: a);
  final Animation<double> a;
  final Color tone;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final t = Curves.easeOutCubic.transform(a.value);
    // From well outside the card in to its corners.
    final gap = 18 * (1 - t);
    final arm = math.min(22.0, size.shortestSide * 0.16);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..color = tone.withOpacity(0.35 + 0.55 * t);
    final l = -gap + 1;
    final tp = -gap + 1;
    final r = size.width + gap - 1;
    final b = size.height + gap - 1;
    for (final (x, y, dx, dy) in [(l, tp, 1.0, 1.0), (r, tp, -1.0, 1.0), (l, b, 1.0, -1.0), (r, b, -1.0, -1.0)]) {
      final path = Path()
        ..moveTo(x, y + dy * arm)
        ..lineTo(x, y + dy * radius * 0.4)
        ..quadraticBezierTo(x, y, x + dx * radius * 0.4, y)
        ..lineTo(x + dx * arm, y);
      canvas.drawPath(path, p);
    }
    // The flash as it locks.
    if (a.value > 0.55 && a.value < 1) {
      final f = 1 - (a.value - 0.55) / 0.45;
      canvas.drawRRect(
        RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(radius)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = tone.withOpacity(0.6 * f),
      );
    }
  }

  @override
  bool shouldRepaint(_LockOnPainter old) => old.a != a || old.tone != tone;
}

// ── AgentHudTag ──────────────────────────────────────────────────────────────

/// "BRIEF", "LIVE": a small tag with a breathing dot.
class AgentHudTag extends StatefulWidget {
  const AgentHudTag(this.label, {super.key, this.color = _cyan});

  final String label;
  final Color color;

  @override
  State<AgentHudTag> createState() => _AgentHudTagState();
}

class _AgentHudTagState extends State<AgentHudTag> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_still(context)) {
      _c.value = 1;
    } else if (!_c.isAnimating) {
      _c.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          color: widget.color.withOpacity(0.10),
          border: Border.all(color: widget.color.withOpacity(0.45)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          FadeTransition(
            opacity: Tween(begin: 0.3, end: 1.0).animate(_c),
            child: Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.color,
                boxShadow: [BoxShadow(color: widget.color, blurRadius: 4)],
              ),
            ),
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(widget.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: widget.color, fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 1.6)),
          ),
        ]),
      );
}
