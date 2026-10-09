// BROKA - the Buying Agent's HUD (2026-10-09).
//
// The motion pass (agent_motion.dart) made the agent's work visible. This
// one is about how it feels to be in the room with it: the Buying Agent is
// the most capable thing in BROKA, and it should look like an instrument,
// not a chat. Everything here is drawn - no images, no shaders compiled at
// run time - in the brand's three colours:
//
//   AgentHoloBackdrop   the room: a deep field, aurora drifting through
//                       it, a holographic floor running to the horizon,
//                       motes rising, a scan line passing - and, on
//                       arrival, a burst of light from where Zeno sits.
//   AgentHudBeam        a line of light running along an edge.
//   AgentHoloBorder     a gradient edge that turns while something is live.
//   AgentThinkingWave   Zeno thinking: interfering waves, not three dots.
//   AgentLockOn         targeting brackets closing on a result.
//   AgentHudTag         a small labelled tag with a live dot.
//
// Like the motion pass: each honours reduce-motion (the layout is the same,
// nothing moves), loops drive painters from their controllers rather than
// rebuilding, and each painter sits behind a RepaintBoundary.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../main.dart' show BrokaColors;
import '../../../../theme/motion.dart';

const _violet = BrokaColors.neonPurple;
const _blue = BrokaColors.neonBlue;
const _cyan = BrokaColors.neonCyan;

bool _still(BuildContext context) => BrokaMotion.reduced(context);

void _loop(AnimationController c, BuildContext context, {bool animate = true}) {
  if (!animate || _still(context)) {
    if (c.isAnimating) c.stop();
  } else if (!c.isAnimating) {
    c.repeat();
  }
}

// ── AgentHoloBackdrop ────────────────────────────────────────────────────────

class AgentHoloBackdrop extends StatefulWidget {
  const AgentHoloBackdrop({super.key, required this.child, this.animate = true});

  final Widget child;

  /// False draws one still frame - for tests.
  final bool animate;

  @override
  State<AgentHoloBackdrop> createState() => _AgentHoloBackdropState();
}

class _AgentHoloBackdropState extends State<AgentHoloBackdrop> with TickerProviderStateMixin {
  // One long loop for everything that drifts; the floor and the motes run
  // at whole multiples of it, so it wraps without a jump.
  late final AnimationController _t;
  late final AnimationController _arrive;
  final _motes = List.generate(46, (i) => _Mote(math.Random(i * 7919 + 13)));

  @override
  void initState() {
    super.initState();
    _t = AnimationController(vsync: this, duration: const Duration(seconds: 24), value: 0.3);
    _arrive = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loop(_t, context, animate: widget.animate);
    if (!_arrive.isAnimating && !_arrive.isCompleted) {
      if (!widget.animate || _still(context)) {
        _arrive.value = 1;
      } else {
        _arrive.forward();
      }
    }
  }

  @override
  void dispose() {
    _t.dispose();
    _arrive.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(fit: StackFit.expand, children: [
        Positioned.fill(
          child: RepaintBoundary(
            child: CustomPaint(painter: _BackdropPainter(_t, _arrive, _motes)),
          ),
        ),
        widget.child,
      ]);
}

class _Mote {
  _Mote(math.Random r)
      : x = r.nextDouble(),
        y = r.nextDouble(),
        speed = 0.6 + r.nextDouble() * 1.6,
        size = 0.6 + r.nextDouble() * 1.6,
        phase = r.nextDouble(),
        cyan = r.nextBool();

  final double x;
  final double y;
  final double speed;
  final double size;
  final double phase;
  final bool cyan;
}

class _BackdropPainter extends CustomPainter {
  _BackdropPainter(this.t, this.arrive, this.motes) : super(repaint: Listenable.merge([t, arrive]));

  final Animation<double> t;
  final Animation<double> arrive;
  final List<_Mote> motes;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final v = t.value;
    final rect = Offset.zero & size;

    // The field.
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF0B0724), Color(0xFF05060F), Color(0xFF03040A)],
          stops: [0.0, 0.5, 1.0],
        ).createShader(rect),
    );

    // Aurora: two slow clouds of colour crossing each other.
    void cloud(Offset c, double r, Color color) {
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..shader = RadialGradient(colors: [color, color.withOpacity(0)])
              .createShader(Rect.fromCircle(center: c, radius: r)),
      );
    }

    final a = v * 2 * math.pi;
    cloud(Offset(w * (0.25 + 0.18 * math.sin(a)), h * (0.16 + 0.06 * math.cos(a * 2))), w * 0.75,
        _violet.withOpacity(0.20));
    cloud(Offset(w * (0.8 - 0.16 * math.cos(a)), h * (0.34 + 0.08 * math.sin(a))), w * 0.6,
        _cyan.withOpacity(0.09));
    cloud(Offset(w * 0.5, h * 1.02), w * 0.9, _blue.withOpacity(0.10));

    // The floor: a holographic grid running to a horizon, coming towards
    // the viewer.
    final horizon = h * 0.60;
    final floorH = h - horizon;
    final vanish = Offset(w / 2, horizon);
    final line = Paint()..strokeWidth = 1;
    const rows = 14;
    final travel = (v * 6) % 1.0;
    for (var i = 0; i < rows; i++) {
      // Depth 0 at the horizon, 1 at the bottom edge, spaced as a floor
      // seen in perspective is.
      final d = (i + travel) / rows;
      final y = horizon + floorH * d * d;
      line.color = _violet.withOpacity(0.05 + 0.20 * d);
      canvas.drawLine(Offset(0, y), Offset(w, y), line);
    }
    const cols = 16;
    for (var i = -cols; i <= cols; i++) {
      final x = w / 2 + i * (w / cols) * 1.6;
      line.color = _cyan.withOpacity(0.10 * (1 - (i.abs() / cols) * 0.6));
      canvas.drawLine(vanish, Offset(x, h), line);
    }
    // The floor fades into the dark at the horizon.
    canvas.drawRect(
      Rect.fromLTWH(0, horizon - 2, w, floorH * 0.55),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [const Color(0xFF05060F), const Color(0xFF05060F).withOpacity(0)],
        ).createShader(Rect.fromLTWH(0, horizon - 2, w, floorH * 0.55)),
    );
    // The horizon line itself, glowing.
    canvas.drawRect(
      Rect.fromLTWH(0, horizon - 1, w, 2),
      Paint()
        ..shader = LinearGradient(colors: [
          _cyan.withOpacity(0),
          _cyan.withOpacity(0.35),
          _violet.withOpacity(0.35),
          _violet.withOpacity(0),
        ]).createShader(Rect.fromLTWH(0, horizon - 1, w, 2)),
    );

    // Motes rising and twinkling.
    final mote = Paint();
    for (final m in motes) {
      final y = (m.y - v * m.speed * 2) % 1.0;
      final twinkle = 0.35 + 0.65 * (0.5 + 0.5 * math.sin((v * 8 + m.phase) * 2 * math.pi));
      mote.color = (m.cyan ? _cyan : _violet).withOpacity(0.55 * twinkle * (1 - y * 0.4));
      canvas.drawCircle(Offset(m.x * w, y * h), m.size, mote);
    }

    // A scan line passing down the room, now and then.
    final scan = (v * 3) % 1.0;
    if (scan < 0.5) {
      final y = h * (scan / 0.5);
      canvas.drawRect(
        Rect.fromLTWH(0, y - 40, w, 40),
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [_cyan.withOpacity(0), _cyan.withOpacity(0.05)],
          ).createShader(Rect.fromLTWH(0, y - 40, w, 40)),
      );
      canvas.drawLine(Offset(0, y), Offset(w, y), Paint()..color = _cyan.withOpacity(0.10));
    }

    // Arrival: light bursting from where Zeno sits, once.
    final e = arrive.value;
    if (e > 0 && e < 1) {
      final c = Offset(w / 2, h * 0.22);
      final r = Curves.easeOutCubic.transform(e) * math.max(w, h) * 1.1;
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..shader = RadialGradient(colors: [
            Colors.white.withOpacity(0.0),
            _cyan.withOpacity(0.22 * (1 - e)),
            _violet.withOpacity(0.0),
          ], stops: const [0.0, 0.85, 1.0])
              .createShader(Rect.fromCircle(center: c, radius: math.max(r, 1))),
      );
      canvas.drawCircle(
        c,
        r * 0.98,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = _cyan.withOpacity(0.55 * (1 - e)),
      );
    }
  }

  @override
  bool shouldRepaint(_BackdropPainter old) => old.t != t || old.arrive != arrive;
}

// ── AgentHudBeam ─────────────────────────────────────────────────────────────

/// A hairline with a pulse of light running along it.
class AgentHudBeam extends StatefulWidget {
  const AgentHudBeam({super.key, this.height = 1.5, this.busy = false});

  final double height;

  /// Faster and brighter while the agent works.
  final bool busy;

  @override
  State<AgentHudBeam> createState() => _AgentHudBeamState();
}

class _AgentHudBeamState extends State<AgentHudBeam> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 3200));

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
        height: widget.height,
        width: double.infinity,
        child: RepaintBoundary(child: CustomPaint(painter: _BeamLinePainter(_c, busy: widget.busy))),
      );
}

class _BeamLinePainter extends CustomPainter {
  _BeamLinePainter(this.a, {required this.busy}) : super(repaint: a);
  final Animation<double> a;
  final bool busy;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(colors: [
          _violet.withOpacity(0.05),
          _violet.withOpacity(0.35),
          _cyan.withOpacity(0.35),
          _cyan.withOpacity(0.05),
        ]).createShader(rect),
    );
    final p = ((a.value * (busy ? 2 : 1)) % 1.0);
    final w = size.width * 0.28;
    final x = -w + (size.width + w) * Curves.easeInOut.transform(p);
    final beam = Rect.fromLTWH(x, 0, w, size.height);
    canvas.drawRect(
      beam,
      Paint()
        ..shader = LinearGradient(colors: [
          _cyan.withOpacity(0),
          Colors.white.withOpacity(busy ? 0.95 : 0.7),
          _cyan.withOpacity(0),
        ]).createShader(beam),
    );
  }

  @override
  bool shouldRepaint(_BeamLinePainter old) => old.a != a || old.busy != busy;
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
class AgentThinkingWave extends StatefulWidget {
  const AgentThinkingWave({super.key, this.label = 'Zeno is thinking'});

  final String label;

  @override
  State<AgentThinkingWave> createState() => _AgentThinkingWaveState();
}

class _AgentThinkingWaveState extends State<AgentThinkingWave> with SingleTickerProviderStateMixin {
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
  Widget build(BuildContext context) => Semantics(
        liveRegion: true,
        label: widget.label,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
          child: Align(
            alignment: Alignment.centerLeft,
            child: AgentHoloBorder(
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
                  SizedBox(
                    width: 64,
                    height: 22,
                    child: RepaintBoundary(child: CustomPaint(painter: _WavePainter(_c))),
                  ),
                  const SizedBox(width: 10),
                  Text(widget.label.toUpperCase(),
                      style: const TextStyle(
                          color: _cyan, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1.5)),
                ]),
              ),
            ),
          ),
        ),
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
