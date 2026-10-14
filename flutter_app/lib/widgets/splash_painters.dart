// Visual-effects painters for the BROKA "AI boot sequence" splash screen.
//
// These establish the futuristic design language described in the splash
// spec (deep navy backdrop, neural-network mesh, concentric orbital rings
// around the Zeno core). The flowing digital wave that ran along the bottom
// was removed with the splash's sound (2026-10-09): too much on screen
// for something people see every time they open the app. They're kept separate
// from splash_screen.dart - and written as plain, configurable
// CustomPainters rather than splash-only internals - so the same pieces
// can be reused when the login screen and other screens go through this
// redesign next.
//
// Note: an earlier pass here also drew a partial "planetary limb" arc in
// the upper-right. It never read convincingly as a sphere (came across as
// a flat wedge instead) and was removed rather than continuing to chase it.
import 'dart:math';
import 'package:flutter/material.dart';
import '../main.dart';

/// Clamp helper. `num.clamp()` returns `num` even when called on a double,
/// which forces awkward casts everywhere it's used with Canvas APIs that
/// require a concrete `double` - this keeps every call site clean.
double _clampD(double v, double lo, double hi) {
  if (v < lo) return lo;
  if (v > hi) return hi;
  return v;
}

// ─────────────────────────────────────────────────────────────────────────
// Neural network mesh
// ─────────────────────────────────────────────────────────────────────────

class NeuralNetworkNode {
  final double dx; // fractional position within the painter's bounds (0..1)
  final double dy;
  final double size;
  final double pulseSeed;
  const NeuralNetworkNode(this.dx, this.dy, this.size, this.pulseSeed);
}

/// Generates a constellation-like node/edge layout once (seeded, so it's
/// identical every run) rather than recomputing it every frame or every
/// widget rebuild. Nodes [0, _networkCount) form the connected mesh in the
/// upper-left; nodes after that are unconnected ambient "stars" scattered
/// more broadly, matching the sparse background dots visible across the
/// whole reference image, not just within the constellation cluster.
class NeuralNetworkField {
  static const int _networkCount = 26;
  static const int _starCount = 20;

  static final List<NeuralNetworkNode> nodes = _generateNodes();
  static final List<List<int>> edges = _generateEdges(nodes, _networkCount);

  static List<NeuralNetworkNode> _generateNodes() {
    final rnd = Random(1337);
    final list = <NeuralNetworkNode>[];
    for (int i = 0; i < _networkCount; i++) {
      // Product of two uniforms biases positions toward the upper-left
      // corner (denser near the corner, sparser toward the centre) without
      // needing dart:math's pow() and its num/double ambiguity.
      final biased = rnd.nextDouble() * rnd.nextDouble();
      final dx = biased * 0.58;
      final dy = 0.02 + rnd.nextDouble() * 0.42;
      final size = 2.2 + rnd.nextDouble() * 3.6;
      list.add(NeuralNetworkNode(dx, dy, size, rnd.nextDouble()));
    }
    for (int i = 0; i < _starCount; i++) {
      final dx = rnd.nextDouble() * 0.95;
      final dy = rnd.nextDouble() * 0.55;
      final size = 1.0 + rnd.nextDouble() * 1.7;
      list.add(NeuralNetworkNode(dx, dy, size, rnd.nextDouble()));
    }
    return list;
  }

  static List<List<int>> _generateEdges(List<NeuralNetworkNode> nodes, int networkCount) {
    final edges = <List<int>>[];
    for (int i = 0; i < networkCount; i++) {
      final dists = <MapEntry<int, double>>[];
      for (int j = 0; j < networkCount; j++) {
        if (i == j) continue;
        final ddx = nodes[i].dx - nodes[j].dx;
        final ddy = nodes[i].dy - nodes[j].dy;
        dists.add(MapEntry(j, ddx * ddx + ddy * ddy));
      }
      dists.sort((a, b) => a.value.compareTo(b.value));
      final linkCount = min(2, dists.length);
      for (int k = 0; k < linkCount; k++) {
        if (dists[k].value > 0.055) continue; // keep the mesh local/sparse
        final j = dists[k].key;
        final a = i < j ? i : j;
        final b = i < j ? j : i;
        final exists = edges.any((e) => e[0] == a && e[1] == b);
        if (!exists) edges.add([a, b]);
      }
    }
    return edges;
  }
}

class NeuralNetworkPainter extends CustomPainter {
  final double t; // continuous time driver, radians-safe (used inside sin())
  final double reveal; // 0..1 boot-phase opacity ramp
  final List<NeuralNetworkNode> nodes;
  final List<List<int>> edges;

  NeuralNetworkPainter({
    required this.t,
    required this.reveal,
    required this.nodes,
    required this.edges,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (reveal <= 0.0) return;
    final positions = <Offset>[
      for (final n in nodes) Offset(n.dx * size.width, n.dy * size.height),
    ];

    final linePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;
    for (final e in edges) {
      final a = positions[e[0]];
      final b = positions[e[1]];
      // A gentle shimmer keyed off horizontal position (not a random
      // per-edge phase) so nearby edges brighten together like a slow wave
      // sweeping the mesh, rather than flickering independently - reads as
      // steady rather than busy.
      final midX = (nodes[e[0]].dx + nodes[e[1]].dx) * 0.5;
      final pulse = 0.5 + 0.5 * sin(t * 2 * pi * 0.22 - midX * 3.2);
      linePaint.color = BrokaColors.gold.withOpacity((0.14 + 0.12 * pulse) * reveal);
      canvas.drawLine(a, b, linePaint);
    }

    for (int i = 0; i < nodes.length; i++) {
      final n = nodes[i];
      final p = positions[i];
      final pulse = 0.5 + 0.5 * sin(t * 2 * pi * 0.20 + n.pulseSeed * 4.0);
      final base = i % 3 == 0 ? BrokaColors.neonBlue : BrokaColors.gold;
      final opacity = (0.55 + 0.45 * pulse) * reveal;
      canvas.drawCircle(
        p,
        n.size * 3.4,
        Paint()
          ..color = base.withOpacity(0.24 * opacity)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
      );
      canvas.drawCircle(p, n.size, Paint()..color = base.withOpacity(opacity));
      canvas.drawCircle(p, n.size * 0.42, Paint()..color = Colors.white.withOpacity(0.6 * opacity));
    }
  }

  @override
  bool shouldRepaint(covariant NeuralNetworkPainter oldDelegate) =>
      oldDelegate.t != t || oldDelegate.reveal != reveal;
}

// ─────────────────────────────────────────────────────────────────────────
// Orbital rings around the Zeno core
// ─────────────────────────────────────────────────────────────────────────

class OrbitRingPainter extends CustomPainter {
  final int dotCount;
  final double dotRadius;
  final List<Color> colors; // gradient stops applied across the ring's dots
  final double strokeOpacity;
  final double reveal;
  final bool dashed;
  final double? cometAngle; // radians; null = no traveling particle
  final Color cometColor;

  const OrbitRingPainter({
    required this.dotCount,
    required this.dotRadius,
    required this.colors,
    required this.strokeOpacity,
    required this.reveal,
    this.dashed = false,
    this.cometAngle,
    this.cometColor = Colors.white,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (reveal <= 0.0) return;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - dotRadius;

    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..color = colors.first.withOpacity(strokeOpacity * reveal);
    if (dashed) {
      _drawDashedCircle(canvas, center, radius, ringPaint);
    } else {
      canvas.drawCircle(center, radius, ringPaint);
    }

    for (int i = 0; i < dotCount; i++) {
      final angle = (i / dotCount) * 2 * pi;
      final p = center + Offset(cos(angle), sin(angle)) * radius;
      final colorT = dotCount <= 1 ? 0.0 : i / (dotCount - 1);
      final color = _lerpMulti(colors, colorT);
      final big = i % 3 == 0;
      final r = big ? dotRadius * 1.5 : dotRadius;
      final op = (big ? 0.85 : 0.5) * reveal;
      if (big) {
        canvas.drawCircle(
          p,
          r * 2.4,
          Paint()
            ..color = color.withOpacity(0.16 * reveal)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
        );
      }
      canvas.drawCircle(p, r, Paint()..color = color.withOpacity(op));
    }

    final angle0 = cometAngle;
    if (angle0 != null) {
      for (int k = 0; k < 10; k++) {
        final trailAngle = angle0 - k * 0.05;
        final p = center + Offset(cos(trailAngle), sin(trailAngle)) * radius;
        final fade = 1.0 - (k / 10.0);
        final op = fade * 0.85 * reveal;
        final rr = _clampD(1.6 - k * 0.12, 0.4, 2.0);
        canvas.drawCircle(p, rr, Paint()..color = cometColor.withOpacity(op));
      }
    }
  }

  void _drawDashedCircle(Canvas canvas, Offset center, double radius, Paint paint) {
    const double dashLength = 6.0;
    const double gapLength = 5.0;
    final circumference = 2 * pi * radius;
    final dashAngle = dashLength / radius;
    final gapAngle = gapLength / radius;
    final step = dashAngle + gapAngle;
    final count = (circumference / (dashLength + gapLength)).floor();
    double angle = 0.0;
    for (int i = 0; i < count; i++) {
      canvas.drawArc(Rect.fromCircle(center: center, radius: radius), angle, dashAngle, false, paint);
      angle += step;
    }
  }

  Color _lerpMulti(List<Color> stops, double t) {
    if (stops.length == 1) return stops[0];
    final scaled = t * (stops.length - 1);
    var i = scaled.floor();
    if (i < 0) i = 0;
    if (i > stops.length - 2) i = stops.length - 2;
    final localT = scaled - i;
    return Color.lerp(stops[i], stops[i + 1], localT)!;
  }

  @override
  bool shouldRepaint(covariant OrbitRingPainter oldDelegate) =>
      oldDelegate.reveal != reveal || oldDelegate.cometAngle != cometAngle;
}

// ─────────────────────────────────────────────────────────────────────────
// Activity dots (boot progress row)
// ─────────────────────────────────────────────────────────────────────────

class ActivityDotsPainter extends CustomPainter {
  final int count;
  final double sweep; // position of the bright point, roughly -0.25..1.25
  final double reveal;

  const ActivityDotsPainter({required this.count, required this.sweep, required this.reveal});

  @override
  void paint(Canvas canvas, Size size) {
    if (reveal <= 0.0 || count < 2) return;
    for (int i = 0; i < count; i++) {
      final xFrac = i / (count - 1);
      final x = xFrac * size.width;
      final baseColor = Color.lerp(BrokaColors.gold, BrokaColors.neonBlue, xFrac)!;
      final dist = (xFrac - sweep).abs();
      final glow = _clampD(1.0 - dist * 2.6, 0.0, 1.0);
      final r = 3.0 + glow * 2.0;
      final op = _clampD(0.32 + 0.68 * glow, 0.0, 1.0) * reveal;
      if (glow > 0.5) {
        canvas.drawCircle(
          Offset(x, size.height / 2),
          r * 2.2,
          Paint()
            ..color = Colors.white.withOpacity(0.30 * glow * reveal)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
        );
      }
      final dotColor = glow > 0.65
          ? Color.lerp(baseColor, Colors.white, _clampD((glow - 0.65) / 0.35, 0.0, 1.0))!
          : baseColor;
      canvas.drawCircle(Offset(x, size.height / 2), r, Paint()..color = dotColor.withOpacity(op));
    }
  }

  @override
  bool shouldRepaint(covariant ActivityDotsPainter oldDelegate) =>
      oldDelegate.sweep != sweep || oldDelegate.reveal != reveal;
}
