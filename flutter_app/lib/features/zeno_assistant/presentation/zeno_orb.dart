// Zeno's orb - what the user talks to in voice mode.
//
// It is the whole of voice mode's feedback, so each state has to be told
// apart at a glance, from across a room:
//
//   waking     rings collapsing inward while the microphone comes up
//   listening  the plasma swells with the user's voice, the spectrum ring
//              around it dances to the microphone level, and particles are
//              drawn in towards it
//   thinking   the plasma knots and spins, a comet circles, particles swirl
//   speaking   the orb pulses to a speech rhythm and throws ripples out
//   error      it dims and stills
//
// and [burst] fires a shockwave - an action has been taken.
//
// 2026-10-10: with [face], Zeno's own face sits at the heart of it - the
// avatar Home, the nav bar and every chat show - so voice mode is plainly
// BROKA's Zeno, not a generic glowing blob. It swells a little with the
// voice it hears and the words it says.
//
// 2026-10-12 (later): the globe's wireframe is now a sphere of linked
// points the voice moves (_swarm) - it ripples with the user's voice, wrings
// itself while Zeno thinks and runs bands of light as it speaks.
//
// 2026-10-12: with [hologram], voice mode's centre is a wireframe globe
// turning inside three gyroscope rings, a scan line sweeping it - in place
// of the face, which made the full-screen assistant look like a toy. The
// globe spins faster as Zeno thinks, the rings widen with the voice, and the
// scan line runs while it listens.
//
// Performance: one Ticker drives a model the painter listens to, so a frame
// repaints this orb and nothing else - no setState, no rebuild of the
// captions or the conversation underneath. Glows are gradients rather than
// blurs, except one soft blur on the outer plasma. Under reduced motion there
// is no ticker at all: the orb is drawn once, in its state's colours.
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show PointMode;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../main.dart' show BrokaColors;
import '../../../theme/motion.dart';
import '../../../widgets/zeno_avatar.dart';

enum ZenoOrbMode { waking, listening, thinking, speaking, error }

class ZenoOrb extends StatefulWidget {
  const ZenoOrb({
    super.key,
    required this.mode,
    this.level = 0,
    this.burst = 0,
    this.size = 280,
    this.face = false,
    this.hologram = false,
  });

  final ZenoOrbMode mode;

  /// Microphone loudness, 0..1 (ZenoVoiceController.level).
  final double level;

  /// Goes up by one for each shockwave.
  final int burst;
  final double size;

  /// Zeno's face at the centre.
  final bool face;

  /// A turning wireframe globe and gyroscope rings at the centre, in place
  /// of the plasma (voice mode).
  final bool hologram;

  @override
  State<ZenoOrb> createState() => _ZenoOrbState();
}

class _ZenoOrbState extends State<ZenoOrb> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  final _model = _OrbModel();
  Duration _last = Duration.zero;

  bool get _still => BrokaMotion.reduced(context);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _model.mode = widget.mode;
    if (_still) {
      if (_ticker.isActive) _ticker.stop();
      _model.settle(widget.level);
    } else if (!_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  @override
  void didUpdateWidget(ZenoOrb old) {
    super.didUpdateWidget(old);
    _model.mode = widget.mode;
    _model.level = widget.level;
    if (widget.burst > old.burst) _model.shockwave();
    if (_still) _model.settle(widget.level);
  }

  @override
  void dispose() {
    _ticker.dispose();
    _model.dispose();
    super.dispose();
  }

  void _tick(Duration elapsed) {
    final dt = ((elapsed - _last).inMicroseconds / 1e6).clamp(0.0, 0.05);
    _last = elapsed;
    _model.advance(dt, widget.level);
  }

  @override
  Widget build(BuildContext context) => Semantics(
        label: switch (widget.mode) {
          ZenoOrbMode.waking => 'Zeno is getting ready',
          ZenoOrbMode.listening => 'Zeno is listening',
          ZenoOrbMode.thinking => 'Zeno is thinking',
          ZenoOrbMode.speaking => 'Zeno is speaking',
          ZenoOrbMode.error => 'Voice stopped',
        },
        child: RepaintBoundary(
          child: SizedBox.square(
            dimension: widget.size,
            child: CustomPaint(
              painter: _OrbPainter(_model, hologram: widget.hologram),
              child: widget.face
                  ? Center(
                      // Rebuilds only the transform each frame; the image
                      // is built once.
                      child: AnimatedBuilder(
                        animation: _model,
                        builder: (_, child) => Opacity(
                          opacity: 1 - 0.45 * _model.mix[ZenoOrbMode.error]!,
                          child: Transform.scale(
                            scale: 1 + 0.05 * _model.energy + 0.05 * _model.voice,
                            child: child,
                          ),
                        ),
                        child: ZenoAvatar(size: widget.size * 0.34, glow: true),
                      ),
                    )
                  : null,
            ),
          ),
        ),
      );
}

// ── Model ────────────────────────────────────────────────────────────────────

class _Particle {
  _Particle(math.Random r) {
    reset(r, anywhere: true);
  }

  double angle = 0;
  double dist = 1; // multiples of the orb radius
  double speed = 0;
  double size = 1;
  double hue = 0;

  void reset(math.Random r, {bool anywhere = false, bool inner = false}) {
    angle = r.nextDouble() * math.pi * 2;
    dist = inner ? 0.95 + r.nextDouble() * 0.2 : (anywhere ? 1.1 + r.nextDouble() * 0.9 : 1.8 + r.nextDouble() * 0.3);
    speed = 0.4 + r.nextDouble() * 0.8;
    size = 0.8 + r.nextDouble() * 1.8;
    hue = r.nextDouble();
  }
}

class _OrbModel extends ChangeNotifier {
  final _rnd = math.Random(7);
  late final List<_Particle> particles = List.generate(64, (_) => _Particle(_rnd));

  ZenoOrbMode mode = ZenoOrbMode.waking;
  double level = 0;

  /// Seconds of animation so far.
  double t = 0;

  /// How much the orb is moving, 0..1, eased towards what the state and
  /// the microphone ask for so it never jumps.
  double energy = 0.2;

  /// Speed of the plasma's churn, eased the same way.
  double spin = 0.3;

  /// 0..1 per state, cross-faded, so colours change over a moment rather
  /// than a frame.
  final Map<ZenoOrbMode, double> mix = {for (final m in ZenoOrbMode.values) m: m == ZenoOrbMode.waking ? 1 : 0};

  /// Shockwaves in flight: seconds since each fired.
  final List<double> waves = [];

  /// Ripples thrown while speaking: seconds since each.
  final List<double> ripples = [];
  double _nextRipple = 0;

  /// 0..1: the rhythm Zeno's voice is drawn with. The app has no amplitude
  /// for the TTS audio, so this is a speech-like envelope - syllables at
  /// ~4-5 a second, phrases rising and falling - not a measurement.
  double voice = 0;

  void shockwave() => waves.add(0);

  /// Reduced motion: one frame in the state's resting pose.
  void settle(double lvl) {
    level = lvl;
    energy = _targetEnergy(lvl);
    for (final m in ZenoOrbMode.values) {
      mix[m] = m == mode ? 1 : 0;
    }
    notifyListeners();
  }

  double _targetEnergy(double lvl) => switch (mode) {
        ZenoOrbMode.waking => 0.25,
        ZenoOrbMode.listening => 0.28 + 0.9 * lvl.clamp(0.0, 1.0),
        ZenoOrbMode.thinking => 0.55,
        ZenoOrbMode.speaking => 0.35 + 0.6 * voice,
        ZenoOrbMode.error => 0.08,
      };

  void advance(double dt, double lvl) {
    t += dt;
    level = lvl;

    if (mode == ZenoOrbMode.speaking) {
      final syllables = (math.sin(t * math.pi * 2 * 4.6) * 0.5 + 0.5);
      final phrase = (math.sin(t * math.pi * 2 * 0.55) * 0.5 + 0.5);
      final grain = (math.sin(t * 37.0) * math.sin(t * 23.0)).abs();
      voice = (0.25 + 0.55 * syllables * (0.45 + 0.55 * phrase) + 0.2 * grain).clamp(0.0, 1.0);
    } else {
      voice *= 0.85;
    }

    final target = _targetEnergy(lvl);
    // Rises fast (a voice arriving), falls slower (so it doesn't flicker).
    final k = target > energy ? 14.0 : 4.0;
    energy += (target - energy) * (1 - math.exp(-k * dt));

    final spinTarget = switch (mode) {
      ZenoOrbMode.thinking => 2.4,
      ZenoOrbMode.speaking => 1.1,
      ZenoOrbMode.listening => 0.6 + level,
      ZenoOrbMode.waking => 1.6,
      ZenoOrbMode.error => 0.1,
    };
    spin += (spinTarget - spin) * (1 - math.exp(-3 * dt));

    for (final m in ZenoOrbMode.values) {
      final want = m == mode ? 1.0 : 0.0;
      mix[m] = mix[m]! + (want - mix[m]!) * (1 - math.exp(-6 * dt));
    }

    for (final p in particles) {
      switch (mode) {
        case ZenoOrbMode.listening:
        case ZenoOrbMode.waking:
          // Drawn in: the orb is taking the user's voice.
          p.dist -= dt * p.speed * (0.25 + 1.4 * level + (mode == ZenoOrbMode.waking ? 0.4 : 0));
          p.angle += dt * 0.25;
          if (p.dist < 0.92) p.reset(_rnd);
        case ZenoOrbMode.speaking:
          // Thrown out with the words.
          p.dist += dt * p.speed * (0.35 + 1.2 * voice);
          p.angle += dt * 0.15;
          if (p.dist > 2.2) p.reset(_rnd, inner: true);
        case ZenoOrbMode.thinking:
          // A swirl on a ring.
          p.angle += dt * p.speed * 2.6;
          p.dist += (1.35 + 0.15 * math.sin(p.hue * 20 + t) - p.dist) * (1 - math.exp(-2 * dt));
        case ZenoOrbMode.error:
          p.dist += dt * 0.05;
          if (p.dist > 2.2) p.reset(_rnd, inner: true);
      }
    }

    if (mode == ZenoOrbMode.speaking) {
      _nextRipple -= dt;
      if (_nextRipple <= 0 && voice > 0.55) {
        ripples.add(0);
        _nextRipple = 0.32;
      }
    }
    for (var i = 0; i < ripples.length; i++) {
      ripples[i] += dt;
    }
    ripples.removeWhere((r) => r > 1.6);
    for (var i = 0; i < waves.length; i++) {
      waves[i] += dt;
    }
    waves.removeWhere((w) => w > 1.2);

    notifyListeners();
  }
}

// The hologram's points: evenly spread over a unit sphere (a Fibonacci
// lattice), and each one's links to its two nearest neighbours, worked out
// once.
final List<(double, double, double)> _unitSphere = () {
  const n = 260;
  final golden = math.pi * (3 - math.sqrt(5));
  return [
    for (var i = 0; i < n; i++)
      () {
        final y = 1 - (i + 0.5) / n * 2;
        final rho = math.sqrt(1 - y * y);
        return (rho * math.cos(golden * i), y, rho * math.sin(golden * i));
      }(),
  ];
}();

final List<(int, int)> _sphereLinks = () {
  final pts = _unitSphere;
  final links = <(int, int)>{};
  for (var i = 0; i < pts.length; i++) {
    final (xi, yi, zi) = pts[i];
    var best = <(double, int)>[];
    for (var j = 0; j < pts.length; j++) {
      if (j == i) continue;
      final (xj, yj, zj) = pts[j];
      final d = (xi - xj) * (xi - xj) + (yi - yj) * (yi - yj) + (zi - zj) * (zi - zj);
      best.add((d, j));
    }
    best.sort((a, b) => a.$1.compareTo(b.$1));
    for (final (_, j) in best.take(2)) {
      links.add(i < j ? (i, j) : (j, i));
    }
  }
  return links.toList();
}();

// ── Painting ─────────────────────────────────────────────────────────────────

class _Palette {
  const _Palette(this.a, this.b, this.c, this.core);
  final Color a;
  final Color b;
  final Color c;
  final Color core;

  static _Palette lerp(_Palette x, _Palette y, double t) => _Palette(
        Color.lerp(x.a, y.a, t)!,
        Color.lerp(x.b, y.b, t)!,
        Color.lerp(x.c, y.c, t)!,
        Color.lerp(x.core, y.core, t)!,
      );
}

const _palettes = <ZenoOrbMode, _Palette>{
  ZenoOrbMode.waking: _Palette(BrokaColors.neonPurple, BrokaColors.neonBlue, BrokaColors.neonCyan, Color(0xFFE9E3FF)),
  ZenoOrbMode.listening: _Palette(BrokaColors.neonBlue, BrokaColors.neonCyan, BrokaColors.neonPurple, Color(0xFFE6FBFF)),
  ZenoOrbMode.thinking: _Palette(BrokaColors.neonPurple, BrokaColors.neonPink, BrokaColors.neonBlue, Color(0xFFFFE8F6)),
  ZenoOrbMode.speaking: _Palette(BrokaColors.neonCyan, BrokaColors.neonPurple, BrokaColors.neonPink, Colors.white),
  ZenoOrbMode.error: _Palette(Color(0xFF7F1D1D), Color(0xFF4C1D95), Color(0xFF1E293B), Color(0xFFFCA5A5)),
};

class _OrbPainter extends CustomPainter {
  _OrbPainter(this.m, {this.hologram = false}) : super(repaint: m);
  final _OrbModel m;
  final bool hologram;

  _Palette get _palette {
    var p = _palettes[ZenoOrbMode.waking]!;
    var total = 0.0;
    for (final mode in ZenoOrbMode.values) {
      final w = m.mix[mode]!;
      if (w <= 0.001) continue;
      total += w;
      p = _Palette.lerp(p, _palettes[mode]!, w / total);
    }
    return p;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final full = size.shortestSide / 2;
    // The plasma's resting radius; everything else is measured from it.
    final r = full * 0.42 * (1 + 0.1 * m.energy + 0.06 * m.mix[ZenoOrbMode.speaking]! * m.voice);
    final pal = _palette;

    _aura(canvas, c, full, pal);
    _ripples(canvas, c, r, pal);
    _spectrum(canvas, c, r, pal);
    _particles(canvas, c, r, pal);
    if (hologram) {
      _hologram(canvas, c, r, pal);
    } else {
      _plasma(canvas, c, r, pal);
    }
    _core(canvas, c, r * (hologram ? 0.55 : 1.0), pal);
    _comet(canvas, c, r, pal);
    _waking(canvas, c, r, full, pal);
    _shockwaves(canvas, c, r, full, pal);
  }

  void _aura(Canvas canvas, Offset c, double full, _Palette pal) {
    final glow = 0.22 + 0.4 * m.energy;
    canvas.drawCircle(
      c,
      full,
      Paint()
        ..shader = RadialGradient(colors: [
          pal.a.withOpacity(glow * 0.55),
          pal.b.withOpacity(glow * 0.22),
          Colors.transparent,
        ], stops: const [0.0, 0.45, 1.0])
            .createShader(Rect.fromCircle(center: c, radius: full)),
    );
  }

  /// A closed blob: the circle of radius [r], each point pushed out by a
  /// sum of sines whose phases drift with time.
  Path _blob(Offset c, double r, double amp, double phase, int seed) {
    const n = 96;
    final path = Path();
    for (var i = 0; i <= n; i++) {
      final a = i / n * math.pi * 2;
      final wobble = math.sin(a * 3 + phase * 1.3 + seed) * 0.55 +
          math.sin(a * 5 - phase * 0.9 + seed * 2) * 0.3 +
          math.sin(a * 7 + phase * 1.7 + seed * 3) * 0.15;
      final rr = r * (1 + amp * wobble);
      final p = c + Offset(math.cos(a), math.sin(a)) * rr;
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    return path..close();
  }

  void _plasma(Canvas canvas, Offset c, double r, _Palette pal) {
    final phase = m.t * m.spin;
    final amp = 0.05 + 0.16 * m.energy + 0.12 * m.mix[ZenoOrbMode.thinking]!;
    final layers = [
      (pal.a, 1.12, 0, 0.55),
      (pal.b, 1.0, 1, 0.7),
      (pal.c, 0.9, 2, 0.75),
    ];
    for (final (color, scale, seed, alpha) in layers) {
      final rr = r * scale;
      final rect = Rect.fromCircle(center: c, radius: rr * 1.3);
      final paint = Paint()
        ..blendMode = BlendMode.plus
        ..shader = RadialGradient(
          center: Alignment(0.35 * math.cos(phase + seed), 0.35 * math.sin(phase * 0.8 + seed)),
          colors: [color.withOpacity(alpha), color.withOpacity(alpha * 0.35), Colors.transparent],
          stops: const [0.0, 0.62, 1.0],
        ).createShader(rect);
      if (seed == 0) paint.maskFilter = const MaskFilter.blur(BlurStyle.normal, 10);
      canvas.drawPath(_blob(c, rr, amp * (1 + seed * 0.2), phase * (1 + seed * 0.35), seed), paint);
    }
    // A thin bright rim on the middle layer, turning with it.
    canvas.drawPath(
      _blob(c, r, amp * 1.2, phase * 1.35, 1),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..shader = SweepGradient(
          colors: [Colors.transparent, pal.core.withOpacity(0.8), Colors.transparent],
          stops: const [0.0, 0.5, 1.0],
          transform: GradientRotation(phase * 2),
        ).createShader(Rect.fromCircle(center: c, radius: r * 1.3)),
    );
  }

  // ── Hologram ───────────────────────────────────────────────────────────────

  /// A point on a sphere of the globe's frame, turned by [spin] about the
  /// vertical axis and tipped towards the viewer, projected flat. z > 0 is
  /// the near side.
  static (Offset, double) _project(Offset c, double x, double y, double z, double spin) {
    const tilt = 0.42;
    final cs = math.cos(spin), sn = math.sin(spin);
    final x1 = x * cs + z * sn;
    final z1 = -x * sn + z * cs;
    final y2 = y * math.cos(tilt) - z1 * math.sin(tilt);
    final z2 = y * math.sin(tilt) + z1 * math.cos(tilt);
    return (c + Offset(x1, y2), z2);
  }

  /// Draws a closed 3D curve, the near half bright and the far half faint,
  /// as two paths.
  void _curve(Canvas canvas, List<(Offset, double)> pts, Paint near, Paint far) {
    final front = Path(), back = Path();
    bool? wasFront;
    for (var i = 0; i < pts.length; i++) {
      final (p, z) = pts[i];
      final isFront = z >= 0;
      final path = isFront ? front : back;
      if (wasFront != isFront || i == 0) {
        // Join the seam from the previous point so the curve stays whole.
        final prev = i == 0 ? p : pts[i - 1].$1;
        path.moveTo(prev.dx, prev.dy);
      }
      path.lineTo(p.dx, p.dy);
      wasFront = isFront;
    }
    canvas.drawPath(back, far);
    canvas.drawPath(front, near);
  }

  void _hologram(Canvas canvas, Offset c, double r, _Palette pal) {
    final think = m.mix[ZenoOrbMode.thinking]!;
    final speak = m.mix[ZenoOrbMode.speaking]!;
    final radius = r * (0.95 + 0.05 * m.energy + 0.06 * speak * m.voice);
    final spin = m.t * (0.35 + 0.9 * think + 0.25 * m.energy);

    // The glass of the globe: a soft light inside it.
    canvas.drawCircle(
      c,
      radius * 1.05,
      Paint()
        ..blendMode = BlendMode.plus
        ..shader = RadialGradient(colors: [
          pal.b.withOpacity(0.22 + 0.2 * m.energy),
          pal.a.withOpacity(0.08),
          Colors.transparent,
        ], stops: const [0.0, 0.7, 1.0])
            .createShader(Rect.fromCircle(center: c, radius: radius * 1.05)),
    );

    _swarm(canvas, c, radius, spin, pal);

    // Three gyroscope rings, each on its own axis, a satellite riding each.
    final ringR = radius * (1.3 + 0.08 * m.energy + 0.1 * speak * m.voice);
    const tips = [1.15, -0.85, 0.3];
    for (var k = 0; k < 3; k++) {
      final turn = m.t * (0.5 + 0.28 * k + 0.6 * think) * (k.isOdd ? -1 : 1);
      final tip = tips[k];
      (Offset, double) at(double a) {
        // A level circle, tipped about x by [tip], turned about y by [turn].
        final x = ringR * math.cos(a), z0 = ringR * math.sin(a);
        final y = -z0 * math.sin(tip), z = z0 * math.cos(tip);
        return _project(c, x, y, z, turn + spin * 0.3);
      }
      final ringNear = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..shader = SweepGradient(
          colors: [pal.a.withOpacity(0.25), pal.core.withOpacity(0.85), pal.a.withOpacity(0.25)],
          transform: GradientRotation(turn * 2),
        ).createShader(Rect.fromCircle(center: c, radius: ringR));
      final ringFar = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = pal.a.withOpacity(0.14);
      _curve(canvas, [for (var i = 0; i <= 72; i++) at(i / 72 * math.pi * 2)], ringNear, ringFar);

      final (sat, z) = at(m.t * (1.4 + 0.5 * k));
      final lit = z >= 0 ? 1.0 : 0.35;
      canvas.drawCircle(
        sat,
        7 + 4 * m.energy,
        Paint()
          ..blendMode = BlendMode.plus
          ..shader = RadialGradient(colors: [pal.core.withOpacity(0.7 * lit), Colors.transparent])
              .createShader(Rect.fromCircle(center: sat, radius: 7 + 4 * m.energy)),
      );
      canvas.drawCircle(sat, 2.2 + m.energy, Paint()..color = Colors.white.withOpacity(0.9 * lit));
    }
  }

  /// The heart of the hologram: a sphere of points, each tied to its
  /// nearest neighbours, that the voice moves. Listening, the surface
  /// ripples with the microphone; thinking, it wrings itself one way and
  /// the other; speaking, bands of light run pole to pole with the words;
  /// a scan line lights the points it crosses. The near side is bigger and
  /// brighter than the far one, so it reads as a solid turning in space.
  void _swarm(Canvas canvas, Offset c, double radius, double spin, _Palette pal) {
    final think = m.mix[ZenoOrbMode.thinking]!;
    final listen = m.mix[ZenoOrbMode.listening]!;
    final speak = m.mix[ZenoOrbMode.speaking]!;
    final err = m.mix[ZenoOrbMode.error]!;
    final t = m.t;
    final twist = think * 1.7 * math.sin(t * 1.4);
    final scanY = math.sin(t * 1.3) * 0.95;
    final scanGain = 0.25 + 0.75 * listen + 0.4 * think;

    final n = _unitSphere.length;
    final px = Float32List(n), py = Float32List(n), depth = Float32List(n), lit = Float32List(n);
    for (var i = 0; i < n; i++) {
      final (x, y, z) = _unitSphere[i];
      final d = 0.035 * math.sin(3 * x + 2 * y + t * 1.2) +
          listen * m.level * 0.34 * math.sin(7 * y + t * 9) * math.cos(5 * x - t * 7) +
          speak * m.voice * 0.16 * math.sin(11 * y - t * 12) +
          think * 0.07 * math.sin(6 * z + t * 5) -
          err * 0.12;
      final rr = radius * (1 + d);
      final a = twist * y;
      final ca = math.cos(a), sa = math.sin(a);
      final (p, pz) = _project(c, (x * ca + z * sa) * rr, y * rr, (-x * sa + z * ca) * rr, spin);
      px[i] = p.dx;
      py[i] = p.dy;
      depth[i] = (pz / rr).clamp(-1.0, 1.0) * 0.5 + 0.5;
      final band = speak * m.voice * math.max(0.0, math.sin(11 * y - t * 12));
      final scan = (y - scanY) * 10;
      lit[i] = (scanGain * math.exp(-scan * scan) + 0.8 * band).clamp(0.0, 1.0);
    }

    // The mesh: links on the near side only, so the back doesn't knot the
    // front into a tangle.
    final links = <double>[];
    for (final (i, j) in _sphereLinks) {
      if (depth[i] + depth[j] < 1.0) continue;
      links..add(px[i])..add(py[i])..add(px[j])..add(py[j]);
    }
    canvas.drawRawPoints(
      PointMode.lines,
      Float32List.fromList(links),
      Paint()
        ..strokeWidth = 0.7
        ..blendMode = BlendMode.plus
        ..color = pal.c.withOpacity((0.12 + 0.22 * m.energy) * (1 - 0.6 * err)),
    );

    // Points in four depth bands, far to near: one draw call each.
    final bands = List.generate(4, (_) => <double>[]);
    final halos = <double>[], sparks = <double>[];
    for (var i = 0; i < n; i++) {
      final b = (depth[i] * 4).floor().clamp(0, 3);
      bands[b]..add(px[i])..add(py[i]);
      if (depth[i] > 0.62) halos..add(px[i])..add(py[i]);
      if (lit[i] > 0.35) sparks..add(px[i])..add(py[i]);
    }
    canvas.drawRawPoints(
      PointMode.points,
      Float32List.fromList(halos),
      Paint()
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 6 + 5 * m.energy
        ..blendMode = BlendMode.plus
        ..color = pal.b.withOpacity(0.09 + 0.1 * m.energy),
    );
    for (var b = 0; b < 4; b++) {
      final f = (b + 0.5) / 4;
      canvas.drawRawPoints(
        PointMode.points,
        Float32List.fromList(bands[b]),
        Paint()
          ..strokeCap = StrokeCap.round
          ..strokeWidth = 1.0 + 2.4 * f + 0.8 * m.energy * f
          ..color = Color.lerp(pal.a, pal.core, f)!.withOpacity((0.18 + 0.75 * f) * (1 - 0.5 * err)),
      );
    }
    canvas.drawRawPoints(
      PointMode.points,
      Float32List.fromList(sparks),
      Paint()
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 3.2 + 1.5 * m.energy
        ..blendMode = BlendMode.plus
        ..color = Colors.white.withOpacity(0.85),
    );
  }

  void _core(Canvas canvas, Offset c, double r, _Palette pal) {
    final rc = r * (0.38 + 0.14 * m.energy);
    canvas.drawCircle(
      c,
      rc,
      Paint()
        ..blendMode = BlendMode.plus
        ..shader = RadialGradient(colors: [
          pal.core.withOpacity(0.95),
          pal.core.withOpacity(0.25),
          Colors.transparent,
        ], stops: const [0.0, 0.45, 1.0])
            .createShader(Rect.fromCircle(center: c, radius: rc)),
    );
  }

  /// 72 bars round the orb. Listening: they follow the microphone, each at
  /// its own jittering height so it reads as a spectrum. Speaking: the
  /// speech rhythm. Otherwise: a low, slow wave.
  void _spectrum(Canvas canvas, Offset c, double r, _Palette pal) {
    const n = 72;
    final listen = m.mix[ZenoOrbMode.listening]!;
    final speak = m.mix[ZenoOrbMode.speaking]!;
    final base = r * 1.3;
    final paint = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 2.2;
    for (var i = 0; i < n; i++) {
      final a = i / n * math.pi * 2 - math.pi / 2;
      // Each bar on its own oscillator: a spectrum that moves, not a hash
      // that flickers every frame.
      final jitter = 0.5 + 0.5 * math.sin(m.t * (5 + (i * 7) % 11) + i * 1.7);
      final wave = math.sin(a * 4 + m.t * 3) * 0.5 + 0.5;
      final h = r *
          (0.03 +
              0.05 * wave * (1 - listen - speak).clamp(0.0, 1.0) +
              listen * m.level * (0.12 + 0.38 * jitter) +
              speak * m.voice * (0.1 + 0.3 * jitter * wave));
      final from = c + Offset(math.cos(a), math.sin(a)) * base;
      final to = c + Offset(math.cos(a), math.sin(a)) * (base + h);
      paint.color = Color.lerp(pal.b, pal.core, jitter * 0.5)!.withOpacity(0.35 + 0.55 * m.energy);
      canvas.drawLine(from, to, paint);
    }
  }

  void _particles(Canvas canvas, Offset c, double r, _Palette pal) {
    final paint = Paint();
    for (final p in m.particles) {
      final pos = c + Offset(math.cos(p.angle), math.sin(p.angle)) * (r * p.dist);
      // Fade near the orb's edge and at the far end of their travel.
      final fade = ((p.dist - 0.9) * 3).clamp(0.0, 1.0) * ((2.25 - p.dist) * 1.5).clamp(0.0, 1.0);
      if (fade <= 0) continue;
      paint.color = Color.lerp(pal.c, pal.core, p.hue)!.withOpacity(0.75 * fade);
      canvas.drawCircle(pos, p.size * (0.7 + 0.5 * m.energy), paint);
    }
  }

  void _comet(Canvas canvas, Offset c, double r, _Palette pal) {
    final think = m.mix[ZenoOrbMode.thinking]!;
    if (think < 0.02) return;
    final ring = r * 1.55;
    final rect = Rect.fromCircle(center: c, radius: ring);
    for (var k = 0; k < 2; k++) {
      final start = m.t * (3.2 + k * 1.3) * (k.isEven ? 1 : -1) + k * math.pi;
      const sweep = math.pi * 0.7;
      canvas.drawArc(
        rect,
        start,
        sweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = 3
          ..shader = SweepGradient(
            colors: [pal.core.withOpacity(0), pal.core.withOpacity(0.95 * think)],
            stops: const [0.0, sweep / (math.pi * 2)],
            transform: GradientRotation(start),
          ).createShader(rect),
      );
      final head = c + Offset(math.cos(start + sweep), math.sin(start + sweep)) * ring;
      canvas.drawCircle(head, 3.5, Paint()..color = Colors.white.withOpacity(think));
    }
  }

  void _ripples(Canvas canvas, Offset c, double r, _Palette pal) {
    for (final age in m.ripples) {
      final p = (age / 1.6).clamp(0.0, 1.0);
      canvas.drawCircle(
        c,
        r * (1.05 + 1.1 * Curves.easeOutCubic.transform(p)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5 * (1 - p) + 0.5
          ..color = pal.a.withOpacity(0.55 * (1 - p)),
      );
    }
  }

  /// Waking: three rings closing in on the orb.
  void _waking(Canvas canvas, Offset c, double r, double full, _Palette pal) {
    final wake = m.mix[ZenoOrbMode.waking]!;
    if (wake < 0.02) return;
    for (var i = 0; i < 3; i++) {
      final p = ((m.t * 0.9 + i / 3) % 1.0);
      final radius = full * 0.98 - (full * 0.98 - r * 1.1) * Curves.easeInCubic.transform(p);
      canvas.drawCircle(
        c,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..color = pal.c.withOpacity(0.5 * wake * math.sin(p * math.pi)),
      );
    }
  }

  void _shockwaves(Canvas canvas, Offset c, double r, double full, _Palette pal) {
    for (final age in m.waves) {
      final p = (age / 1.2).clamp(0.0, 1.0);
      final e = Curves.easeOutQuart.transform(p);
      canvas.drawCircle(
        c,
        r + (full * 1.1 - r) * e,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 10 * (1 - p) + 1
          ..color = pal.core.withOpacity(0.8 * (1 - p)),
      );
      canvas.drawCircle(
        c,
        r * (1 + 0.5 * (1 - p)),
        Paint()
          ..blendMode = BlendMode.plus
          ..color = pal.core.withOpacity(0.35 * (1 - p)),
      );
    }
  }

  @override
  bool shouldRepaint(_OrbPainter old) => old.m != m || old.hologram != hologram;
}
