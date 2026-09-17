// BROKA — Ambient constellation background for conversation screens
//
// The same visual language as the splash screen's neural-network field
// (widgets/splash_painters.dart), retuned for a surface people actually
// read text on top of, and rebuilt so it can sit behind a scrolling list
// without costing anything.
//
// Three deliberate departures from the splash version:
//
//  1. **Spread, not clustered.** The splash biases nodes hard into the
//     upper-left because the logo owns the centre. A chat screen has no
//     focal point to work around, so nodes are distributed across the
//     whole field with a soft vertical falloff - densest at the top behind
//     the header, thinning toward the composer so it never competes with
//     the text you're typing.
//
//  2. **Far dimmer.** Splash opacities run 0.55-1.0 because it's a hero
//     moment with nothing to read. Behind chat bubbles that would be
//     actively hostile to legibility, so everything here is scaled down to
//     roughly a fifth and the brightest node is dimmer than the faintest
//     body text.
//
//  3. **It does not rebuild its child.** This is the important one.
//     ParticleField (widgets/particle_field.dart) drives its animation with
//     `_ctrl.addListener(() => setState(() {}))`, which rebuilds the entire
//     subtree - including `widget.child` - on every single frame. That is
//     survivable for a static splash screen and would be catastrophic
//     behind a chat list: every message bubble, every image, every
//     RichText re-laid-out 60 times a second while the user scrolls. Here
//     the animation drives ONLY a RepaintBoundary'd CustomPaint via
//     AnimatedBuilder, so the painter repaints and nothing else in the
//     tree is touched.

import 'dart:math';
import 'package:flutter/material.dart';
import '../main.dart';

class _AmbientNode {
  final double dx;
  final double dy;
  final double size;
  final double seed;
  const _AmbientNode(this.dx, this.dy, this.size, this.seed);
}

/// Layout is generated once per process, from a fixed seed, and shared by
/// every conversation screen. Two reasons: the mesh is identical every time
/// you open a chat (so it reads as "the app's background", not as noise
/// that reshuffles), and the O(n²) nearest-neighbour edge pass runs once
/// for the life of the app rather than per screen.
class _AmbientField {
  // Raised from 30/26. At the old density the mesh read as a handful of
  // stray dots rather than a constellation - there simply weren't enough
  // neighbours within linking distance for the eye to see a structure.
  // Nominal portrait aspect ratio, used only to measure link distance in
  // screen space rather than in fraction-of-bounds space (see _edges).
  static const double _aspect = 2.2;

  static const int _nodeCount = 46;
  static const int _starCount = 38;

  static final List<_AmbientNode> nodes = _generate();
  static final List<List<int>> edges = _edges(nodes, _nodeCount);

  static List<_AmbientNode> _generate() {
    final rnd = Random(90210);
    final list = <_AmbientNode>[];
    for (int i = 0; i < _nodeCount; i++) {
      // Soft vertical falloff: nextDouble() squared pushes the distribution
      // toward the top of the screen, leaving the composer area quiet.
      final v = rnd.nextDouble();
      list.add(_AmbientNode(
        rnd.nextDouble(),
        // Softened from v*v to v^1.5-ish: the old squared falloff crushed
        // almost everything into the top fifth of the screen, leaving the
        // large middle of a chat thread empty.
        v * (0.35 + 0.65 * v) * 0.95,
        // Wider size spread. Uniform dots look like noise; a galaxy has a
        // few bright anchors among many faint ones.
        1.5 + rnd.nextDouble() * rnd.nextDouble() * 3.4,
        rnd.nextDouble(),
      ));
    }
    for (int i = 0; i < _starCount; i++) {
      list.add(_AmbientNode(
        rnd.nextDouble(),
        rnd.nextDouble(),
        0.7 + rnd.nextDouble() * 1.1,
        rnd.nextDouble(),
      ));
    }
    return list;
  }

  static List<List<int>> _edges(List<_AmbientNode> nodes, int meshCount) {
    final out = <List<int>>[];
    for (int i = 0; i < meshCount; i++) {
      final dists = <MapEntry<int, double>>[];
      for (int j = 0; j < meshCount; j++) {
        if (i == j) continue;
        final ddx = nodes[i].dx - nodes[j].dx;
        // Scale dy by the screen's aspect ratio before measuring.
        //
        // Node positions are fractions of the painter's bounds, but a
        // phone screen is roughly 2.2x taller than it is wide - so one
        // unit of dy is 2.2x more PIXELS than one unit of dx. Comparing
        // them raw treats a 200px vertical gap as equivalent to a 90px
        // horizontal one, and the nearest-neighbour search happily linked
        // stars that are visually far apart. The result was long lines
        // striping across the whole thread: a network diagram, not a
        // constellation. Measuring in screen space keeps every link
        // visually short, which is what makes the splash's mesh read as
        // clusters of nearby stars.
        final ddy = (nodes[i].dy - nodes[j].dy) * _aspect;
        dists.add(MapEntry(j, ddx * ddx + ddy * ddy));
      }
      dists.sort((a, b) => a.value.compareTo(b.value));
      // 3 links per node instead of 2, over a longer reach. Two links at
      // 0.035 produced a scatter of isolated pairs - the "interconnected"
      // part of interconnected stars was missing.
      for (int k = 0; k < min(3, dists.length); k++) {
        if (dists[k].value > 0.075) continue;
        final j = dists[k].key;
        final a = i < j ? i : j;
        final b = i < j ? j : i;
        if (!out.any((e) => e[0] == a && e[1] == b)) out.add([a, b]);
      }
    }
    return out;
  }
}

class ChatAmbientBackground extends StatefulWidget {
  final Widget child;

  /// Global opacity multiplier. Zeno's own screen can afford a little more
  /// presence than buyer↔seller chat, which is denser with real content.
  final double intensity;

  const ChatAmbientBackground({
    super.key,
    required this.child,
    this.intensity = 1.0,
  });

  @override
  State<ChatAmbientBackground> createState() => _ChatAmbientBackgroundState();
}

class _ChatAmbientBackgroundState extends State<ChatAmbientBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    // 48s for a full cycle. Slow enough that it never pulls the eye off the
    // conversation - you notice it between messages, not during one.
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 48),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Paint against the WINDOW size, not the size this widget was handed.
    //
    // Node positions are fractions of the painter's bounds. When the
    // keyboard opens, Scaffold(resizeToAvoidBottomInset: true) shrinks the
    // body by ~45% of the screen height, so those fractions re-evaluated
    // against the smaller box: every node slid upward and every gap between
    // them closed. The whole constellation visibly shrank and re-flowed the
    // instant the composer was focused, then sprang back on dismiss — which
    // reads as the background being animated BY the keyboard.
    //
    // MediaQuery.size is the full window and does not change with the
    // keyboard (only viewInsets does), so painting at that size and letting
    // OverflowBox hand the painter more height than the parent allows keeps
    // every node at a fixed screen position. Opening the keyboard now crops
    // the field from the bottom, the way a real starfield behind a panel
    // would behave, instead of squashing it.
    //
    // ClipRect stops the overflowing paint escaping the layout box; without
    // it the field would draw over the composer and the system nav bar.
    final window = MediaQuery.of(context).size;

    return Stack(
      fit: StackFit.expand,
      children: [
        // Base gradient. A flat bg would make the constellation look pasted
        // on; a faint radial lift behind it gives the dots something to sit
        // in and matches the splash's depth.
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(-0.6, -0.85),
              radius: 1.5,
              colors: [Color(0xFF1A1036), Color(0xFF0C0818), BrokaColors.bg],
              stops: [0.0, 0.5, 1.0],
            ),
          ),
        ),
        // RepaintBoundary isolates the painter's dirty region from the rest
        // of the tree - without it, every repaint of this layer would mark
        // the whole stack (chat list included) for repaint.
        ClipRect(
          child: OverflowBox(
            alignment: Alignment.topCenter,
            minWidth: window.width,
            maxWidth: window.width,
            minHeight: window.height,
            maxHeight: window.height,
            child: RepaintBoundary(
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: _ctrl,
                  builder: (_, __) => CustomPaint(
                    size: window,
                    painter: _AmbientPainter(
                      t: _ctrl.value,
                      intensity: widget.intensity,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        widget.child,
      ],
    );
  }
}

class _AmbientPainter extends CustomPainter {
  final double t;
  final double intensity;
  _AmbientPainter({required this.t, required this.intensity});

  @override
  void paint(Canvas canvas, Size size) {
    final nodes = _AmbientField.nodes;
    final positions = <Offset>[
      for (final n in nodes) Offset(n.dx * size.width, n.dy * size.height),
    ];

    // Fade the whole field out toward the bottom of the screen, where the
    // composer and the most recent (most-read) messages live.
    double falloff(double dy) {
      // Only really bites in the bottom fifth, where the composer sits.
      // The old linear 0.55 taper dimmed the whole middle of the thread,
      // which is most of what you actually look at.
      if (dy < 0.72) return 1.0;
      return (1.0 - (dy - 0.72) * 2.4).clamp(0.20, 1.0);
    }

    final linePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7;
    for (final e in _AmbientField.edges) {
      final na = nodes[e[0]];
      final nb = nodes[e[1]];
      // Shimmer keyed off position rather than a per-edge random phase, so
      // neighbouring edges brighten together as a slow wave instead of
      // flickering independently. Busy backgrounds behind text are the
      // fastest way to make an app feel cheap.
      final midX = (na.dx + nb.dx) * 0.5;
      final midY = (na.dy + nb.dy) * 0.5;
      final pulse = 0.5 + 0.5 * sin(t * 2 * pi - midX * 3.0);
      // Brightness now tracks the splash's own NeuralNetworkPainter
      // (0.14-0.26 on edges) instead of the ~0.035-0.065 this used before.
      // The original values were chosen to protect legibility and
      // overshot badly: at 4-5x below the splash the lines simply weren't
      // visible, so what reached the screen was a scatter of faint
      // smudges rather than a constellation. Legibility is protected by
      // the message bubbles being opaque and the stars being small
      // points, not by making the points invisible.
      // Raised from 0.13/0.11. The field reads as depth only if it is
      // actually visible in the gaps between cards; at the old values it
      // disappeared entirely behind the dashboard's dense layout, which is
      // the opposite of the intended effect - the cards do the work of
      // protecting legibility, so the links do not have to hide.
      linePaint.color = BrokaColors.gold
          .withOpacity((0.20 + 0.16 * pulse) * falloff(midY) * intensity);
      canvas.drawLine(positions[e[0]], positions[e[1]], linePaint);
    }

    for (int i = 0; i < nodes.length; i++) {
      final n = nodes[i];
      final p = positions[i];
      final pulse = 0.5 + 0.5 * sin(t * 2 * pi + n.seed * 6.28);
      final base = i % 4 == 0 ? BrokaColors.neonBlue : BrokaColors.gold;
      // Raised from 0.42/0.38 for the same reason as the links above.
      final o = (0.58 + 0.42 * pulse) * falloff(n.dy) * intensity;

      // Bloom, then the star, then a white core - the same three-pass
      // build the splash uses. The white core is what actually makes
      // these read as STARS rather than coloured dots: a real point of
      // light blows out to white at the centre and keeps its colour only
      // in the falloff. Dropping it was the single biggest reason the
      // first attempt looked like dust.
      if (n.size > 1.6) {
        canvas.drawCircle(
          p,
          n.size * 3.2,
          Paint()
            ..color = base.withOpacity(0.20 * o)
            // Tighter blur than the splash's 7: a wide bloom behind body
            // text is what would actually hurt readability, far more than
            // the point itself.
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
        );
      }
      canvas.drawCircle(p, n.size, Paint()..color = base.withOpacity(o));
      if (n.size > 1.6) {
        canvas.drawCircle(
          p,
          n.size * 0.40,
          Paint()..color = Colors.white.withOpacity(0.55 * o),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _AmbientPainter old) =>
      old.t != t || old.intensity != intensity;
}
