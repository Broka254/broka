// BROKA — Constellation Background
//
// The deep-space starfield that sits behind the auth screens. It is the same
// visual language as the splash screen's "AI boot sequence": a near-black
// backdrop, a slow violet glow, and a shimmering mesh of nodes and edges.
//
// It deliberately reuses splash_painters.dart's NeuralNetworkPainter rather
// than growing a second copy of that drawing code. What differs is only the
// node LAYOUT: the splash biases its mesh into the upper-left corner so it
// doesn't collide with the centred Zeno core, whereas an auth screen has
// content running its full height and wants stars edge to edge. So this file
// supplies its own full-bleed field and hands it to the shared painter.
//
// Usage: wrap a screen's body in `ConstellationBackground(child: ...)`. The
// widget owns its own animation controller and disposes of it.

import 'dart:math';

import 'package:flutter/material.dart';

import '../main.dart';
import 'splash_painters.dart';

/// A seeded, full-bleed constellation layout.
///
/// Generated once and cached in statics, exactly like [NeuralNetworkField]:
/// the positions must not jump between rebuilds (a rebuild happens on every
/// keystroke in a form) and regenerating them per frame would be wasteful.
/// The seed is fixed so the sky is identical on every launch.
class AuthConstellationField {
  /// Nodes that take part in the connected mesh.
  static const int _meshCount = 46;

  /// Unconnected ambient stars scattered over the whole canvas.
  static const int _starCount = 54;

  /// Edges longer than this (in normalised space, squared) are dropped, which
  /// keeps the mesh reading as local clusters rather than one dense web.
  static const double _maxEdgeDistSq = 0.028;

  static final List<NeuralNetworkNode> nodes = _generateNodes();
  static final List<List<int>> edges = _generateEdges();

  static List<NeuralNetworkNode> _generateNodes() {
    final rnd = Random(20260917);
    final list = <NeuralNetworkNode>[];

    // Mesh nodes: spread over the full canvas, with a mild vertical bias
    // toward the top and bottom thirds so the middle band - where the form
    // fields sit - stays visually quiet and the text keeps its contrast.
    for (int i = 0; i < _meshCount; i++) {
      final dx = rnd.nextDouble();
      final raw = rnd.nextDouble();
      // Push values away from 0.5 (the centre band) without reshaping the
      // overall 0..1 range.
      final dy = raw < 0.5 ? raw * 0.82 : 1.0 - (1.0 - raw) * 0.82;
      final size = 1.8 + rnd.nextDouble() * 2.6;
      list.add(NeuralNetworkNode(dx, dy, size, rnd.nextDouble()));
    }

    // Ambient stars: uniform, smaller, no edges.
    for (int i = 0; i < _starCount; i++) {
      final dx = rnd.nextDouble();
      final dy = rnd.nextDouble();
      final size = 0.8 + rnd.nextDouble() * 1.5;
      list.add(NeuralNetworkNode(dx, dy, size, rnd.nextDouble()));
    }
    return list;
  }

  static List<List<int>> _generateEdges() {
    final n = nodes;
    final edges = <List<int>>[];
    for (int i = 0; i < _meshCount; i++) {
      final dists = <MapEntry<int, double>>[];
      for (int j = 0; j < _meshCount; j++) {
        if (i == j) continue;
        // Compare in an aspect-corrected space. Screens are much taller than
        // they are wide, so raw normalised distance would treat a vertical
        // neighbour as far closer than it looks and draw long vertical
        // streaks across the screen.
        final ddx = n[i].dx - n[j].dx;
        final ddy = (n[i].dy - n[j].dy) * 2.1;
        dists.add(MapEntry(j, ddx * ddx + ddy * ddy));
      }
      dists.sort((a, b) => a.value.compareTo(b.value));
      for (int k = 0; k < min(2, dists.length); k++) {
        if (dists[k].value > _maxEdgeDistSq) continue;
        final j = dists[k].key;
        final a = i < j ? i : j;
        final b = i < j ? j : i;
        if (!edges.any((e) => e[0] == a && e[1] == b)) edges.add([a, b]);
      }
    }
    return edges;
  }
}

/// Deep-space backdrop with a drifting violet glow and a shimmering mesh.
///
/// [child] is laid over the top and receives the full box constraints.
class ConstellationBackground extends StatefulWidget {
  const ConstellationBackground({
    super.key,
    required this.child,
    this.animate = true,
  });

  final Widget child;

  /// Set false to render a single static frame. Useful for tests and for
  /// honouring a reduced-motion preference.
  final bool animate;

  @override
  State<ConstellationBackground> createState() => _ConstellationBackgroundState();
}

class _ConstellationBackgroundState extends State<ConstellationBackground>
    with SingleTickerProviderStateMixin {
  // One controller drives both the glow drift and the mesh shimmer. A single
  // long loop is cheaper than several, and keeping the two layers on the same
  // clock stops them from beating against each other.
  late final AnimationController _t;

  @override
  void initState() {
    super.initState();
    _t = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 24),
    );
    if (widget.animate) _t.repeat();
  }

  @override
  void didUpdateWidget(covariant ConstellationBackground old) {
    super.didUpdateWidget(old);
    if (widget.animate && !_t.isAnimating) {
      _t.repeat();
    } else if (!widget.animate && _t.isAnimating) {
      _t.stop();
    }
  }

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Layer 1 — the backdrop. A radial violet wash that drifts slowly
        // around the upper half, over near-black.
        RepaintBoundary(
          child: AnimatedBuilder(
            animation: _t,
            builder: (_, __) {
              final a = _t.value * 2 * pi;
              return DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment(sin(a) * 0.35, cos(a) * 0.22 - 0.35),
                    radius: 1.25,
                    colors: const [
                      Color(0xFF140B2E), // violet core
                      Color(0xFF080618),
                      BrokaColors.bg,
                    ],
                    stops: const [0.0, 0.45, 1.0],
                  ),
                ),
              );
            },
          ),
        ),

        // Layer 2 — the constellation itself, on its own repaint boundary so
        // form rebuilds above it never force the mesh to redraw.
        RepaintBoundary(
          child: AnimatedBuilder(
            animation: _t,
            builder: (_, __) => CustomPaint(
              painter: NeuralNetworkPainter(
                // The painter reads `t` inside sin(), so feeding it the raw
                // 0..1 loop value keeps the shimmer continuous across wraps.
                t: _t.value * 24,
                reveal: 1.0,
                nodes: AuthConstellationField.nodes,
                edges: AuthConstellationField.edges,
              ),
            ),
          ),
        ),

        // Layer 3 — a bottom vignette. Without it the lower stars compete
        // with the "or" divider and the switch prompt for attention.
        const IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.center,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Color(0xCC03040A)],
              ),
            ),
          ),
        ),

        widget.child,
      ],
    );
  }
}
