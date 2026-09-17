// BROKA Dark Matter — Particle Field Background + Hex Trust Badge
import 'dart:math';
import 'package:flutter/material.dart';
import '../main.dart';

class ParticleField extends StatefulWidget {
  final Widget? child;
  final int particleCount;
  const ParticleField({super.key, this.child, this.particleCount = 60});

  @override
  State<ParticleField> createState() => _ParticleFieldState();
}

class _ParticleFieldState extends State<ParticleField>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final List<_Particle> _particles;
  final _rng = Random();

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(seconds: 60))
      ..repeat();
    _particles = List.generate(widget.particleCount, (_) => _Particle.random(_rng));
    // PERFORMANCE FIX (UI pass, 2026-09-14): this used to be
    // `_ctrl.addListener(() => setState(() {}))`, which rebuilds this
    // widget's ENTIRE subtree - `widget.child` included - on every frame,
    // 60 times a second, forever. Harmless on a static splash screen,
    // ruinous the moment anyone wraps a list or a form in it: every child
    // widget re-laid-out continuously while the user tries to scroll or
    // type. AnimatedBuilder below drives only the painter, and the
    // RepaintBoundary stops the repaint propagating outward.
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      RepaintBoundary(
        child: IgnorePointer(
          child: AnimatedBuilder(
            animation: _ctrl,
            builder: (_, __) => CustomPaint(
              size: Size.infinite,
              painter: _ParticlePainter(_particles, _ctrl.value),
            ),
          ),
        ),
      ),
      if (widget.child != null) widget.child!,
    ],
  );
}

class _Particle {
  double x, y, speed, size, opacity;
  _Particle({required this.x, required this.y, required this.speed,
    required this.size, required this.opacity});
  factory _Particle.random(Random rng) => _Particle(
    x: rng.nextDouble(), y: rng.nextDouble(),
    speed: 0.02 + rng.nextDouble() * 0.06,
    size: 0.8 + rng.nextDouble() * 2.2,
    opacity: 0.08 + rng.nextDouble() * 0.35,
  );
}

class _ParticlePainter extends CustomPainter {
  final List<_Particle> particles;
  final double t;
  _ParticlePainter(this.particles, this.t);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;
    for (final p in particles) {
      final y = (p.y + p.speed * t) % 1.0;
      paint.color = BrokaColors.gold.withOpacity(p.opacity);
      canvas.drawCircle(Offset(p.x * size.width, y * size.height), p.size, paint);
    }
  }

  @override
  bool shouldRepaint(_ParticlePainter o) => o.t != t;
}

// ─── Hex Trust Badge ──────────────────────────────────────────────────────────
class HexTrustBadge extends StatelessWidget {
  final double score;
  final String label;
  final double size;
  const HexTrustBadge({super.key, required this.score, required this.label, this.size = 72});

  Color get _color {
    if (score >= 8) return BrokaColors.neonGreen;
    if (score >= 6) return BrokaColors.gold;
    if (score >= 4) return BrokaColors.warning;
    return BrokaColors.danger;
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size, height: size * 1.15,
    child: Stack(alignment: Alignment.center, children: [
      CustomPaint(size: Size(size, size * 1.15), painter: _HexPainter(color: _color)),
      Column(mainAxisSize: MainAxisSize.min, children: [
        Text(score.toStringAsFixed(1), style: TextStyle(
          color: _color, fontSize: size * 0.22, fontWeight: FontWeight.bold, fontFamily: 'Georgia')),
        Text(label.toUpperCase(), style: TextStyle(
          color: BrokaColors.textMid, fontSize: size * 0.09, letterSpacing: 1.2)),
      ]),
    ]),
  );
}

class _HexPainter extends CustomPainter {
  final Color color;
  _HexPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2; final cy = size.height / 2;
    final r = min(cx, cy) * 0.88;
    final path = Path();
    for (int i = 0; i < 6; i++) {
      final a = (i * 60 - 30) * pi / 180;
      final px = cx + r * cos(a); final py = cy + r * sin(a);
      if (i == 0) path.moveTo(px, py); else path.lineTo(px, py);
    }
    path.close();
    canvas.drawPath(path, Paint()..color = color.withOpacity(0.12)..style = PaintingStyle.fill);
    canvas.drawPath(path, Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 1.5);
  }

  @override
  bool shouldRepaint(_HexPainter o) => o.color != color;
}
