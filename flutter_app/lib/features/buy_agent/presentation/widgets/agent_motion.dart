// BROKA - the Buying Agent's motion.
//
// The Buying Agent is an agent: it asks, it goes off and looks, it comes
// back with things, it keeps watch. The screen it lives on showed all of
// that as one more chat - an italic caption while it searched, listings
// stacked 210px tall down the conversation, a text button for the watch -
// so the most capable thing in the app looked like the plainest. These are
// the pieces that make the work visible:
//
//   AgentOrb            Zeno inside a turning ring: the agent is on.
//   AgentCoreHero       the empty state - Zeno, its light, and how it works.
//   AgentScanCard       a radar scope sweeping the market while it searches.
//   AgentBriefStrip     what Zeno has understood so far, chip by chip.
//   AgentMatchCarousel  the results, dealt in like cards and swiped through.
//   AgentWatchOffer     "keep watching", and the watch once it is on.
//   AgentConfetti       a burst for an exact match or a watch that is set.
//   AgentEntrance       a bubble arriving.
//   AgentLiveEdge       the edge of a reply that is still being written.
//
// 2026-10-09: the HUD pass (agent_hud.dart) gave the agent a room of its
// own and redrew the core as a reactor; the hunt card's edge turns, its
// radar locks on to blips, and results are locked on as they are dealt.
//
// 2026-10-10: back on Home's constellation, with the core calmed down to
// Zeno, its light and one ring; the hunt became a full radar scope; and the
// agent's three steps are Tell me, I hunt, I recommend - it recommends the
// best deal rather than offering to negotiate each result.
//
// Every one honours the OS reduce-motion setting (BrokaMotion.reduced): the
// layout is identical, the motion is not there. The looping ones drive a
// painter from their controller rather than rebuilding, and sit behind a
// RepaintBoundary, so a turning ring repaints the ring and nothing else.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../main.dart' show BrokaColors;
import '../../../../theme/motion.dart';
import '../../../../utils/price_format.dart';
import '../../../../widgets/zeno_avatar.dart';
import 'agent_hud.dart';

/// Home's Zeno CTA and the Buying Agent's header avatar share this tag, so
/// Zeno flies from Home into the agent when it opens.
const String kBuyingAgentHeroTag = 'zeno-buying-agent';

const _violet = BrokaColors.neonPurple;
const _blue = BrokaColors.neonBlue;
const _cyan = BrokaColors.neonCyan;

/// Starts or stops an ambient loop to match the reduce-motion setting.
/// Called from didChangeDependencies, so switching the setting while the
/// screen is open takes effect at once.
void _syncLoop(AnimationController c, BuildContext context, {bool reverse = false}) {
  if (BrokaMotion.reduced(context)) {
    if (c.isAnimating) c.stop();
  } else if (!c.isAnimating) {
    c.repeat(reverse: reverse);
  }
}

/// Plays a one-shot entrance once - or, under reduced motion, jumps to its
/// end so whatever it reveals is simply there.
void _playOnce(AnimationController c, BuildContext context, {required bool play}) {
  if (c.isAnimating || c.isCompleted) return;
  if (!play || BrokaMotion.reduced(context)) {
    c.value = 1.0;
  } else {
    c.forward();
  }
}

// ── AgentOrb ─────────────────────────────────────────────────────────────────

/// Zeno inside a ring with a bright comet running round it - the agent is
/// switched on. With [pings], radar rings ripple outward too: it is
/// watching. The ripples paint outside the widget's box on purpose, so the
/// orb takes the room of the avatar and its ring, not of its halo.
class AgentOrb extends StatefulWidget {
  const AgentOrb({
    super.key,
    this.size = 38,
    this.pings = false,
    this.heroTag,
    this.busy = false,
  });

  /// Zeno's diameter. The ring sits just outside it.
  final double size;
  final bool pings;
  final Object? heroTag;

  /// Working on something: the comet runs twice as fast and brighter.
  final bool busy;

  @override
  State<AgentOrb> createState() => _AgentOrbState();
}

class _AgentOrbState extends State<AgentOrb> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 3600));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncLoop(_c, context);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final outer = widget.size + 10;
    Widget avatar = ZenoAvatar(size: widget.size, glow: true);
    if (widget.heroTag != null) avatar = Hero(tag: widget.heroTag!, child: avatar);
    return SizedBox(
      width: outer,
      height: outer,
      child: Stack(alignment: Alignment.center, clipBehavior: Clip.none, children: [
        Positioned.fill(
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _OrbPainter(_c,
                  avatarSize: widget.size, pings: widget.pings, busy: widget.busy),
            ),
          ),
        ),
        avatar,
      ]),
    );
  }
}

class _OrbPainter extends CustomPainter {
  _OrbPainter(this.a, {required this.avatarSize, required this.pings, required this.busy})
      : super(repaint: a);

  final Animation<double> a;
  final double avatarSize;
  final bool pings;
  final bool busy;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final t = a.value;
    final r = avatarSize / 2 + 3.5;

    if (pings) {
      for (var i = 0; i < 2; i++) {
        final p = (t * 2 + i / 2) % 1.0;
        canvas.drawCircle(
          c,
          r + p * avatarSize * 0.6,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4
            ..color = _cyan.withOpacity((1 - p) * 0.5),
        );
      }
    }

    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.1
        ..color = _violet.withOpacity(0.28),
    );

    final turns = busy ? 4 : 2;
    final start = (t * turns % 1.0) * 2 * math.pi - math.pi / 2;
    const sweep = math.pi * 1.25;
    final rect = Rect.fromCircle(center: c, radius: r);
    canvas.drawArc(
      rect,
      start,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = busy ? 2.6 : 2.1
        ..strokeCap = StrokeCap.round
        ..shader = SweepGradient(
          colors: [_violet.withOpacity(0), _violet, _cyan],
          stops: const [0.0, 0.42, sweep / (2 * math.pi)],
          transform: GradientRotation(start),
        ).createShader(rect),
    );
    final head = c + Offset(math.cos(start + sweep), math.sin(start + sweep)) * r;
    canvas.drawCircle(
        head, 4, Paint()..color = _cyan.withOpacity(0.55)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
    canvas.drawCircle(head, 1.8, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_OrbPainter old) =>
      old.a != a || old.avatarSize != avatarSize || old.pings != pings || old.busy != busy;
}

// ── AgentShimmerText ─────────────────────────────────────────────────────────

/// Text with a band of light running through it, left to right.
class AgentShimmerText extends StatefulWidget {
  const AgentShimmerText(
    this.text, {
    super.key,
    required this.style,
    this.colors = const [_violet, _blue, Colors.white, _cyan, _violet],
    this.textAlign,
    this.maxLines,
  });

  final String text;
  final TextStyle style;
  final List<Color> colors;
  final TextAlign? textAlign;
  final int? maxLines;

  @override
  State<AgentShimmerText> createState() => _AgentShimmerTextState();
}

class _AgentShimmerTextState extends State<AgentShimmerText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2600));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncLoop(_c, context);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Text(
      widget.text,
      textAlign: widget.textAlign,
      maxLines: widget.maxLines,
      overflow: widget.maxLines == null ? null : TextOverflow.ellipsis,
      style: widget.style.copyWith(color: Colors.white),
    );
    return AnimatedBuilder(
      animation: _c,
      child: text,
      builder: (_, child) => ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (rect) => LinearGradient(
          colors: widget.colors,
          transform: _SlideGradient(_c.value),
        ).createShader(rect),
        child: child,
      ),
    );
  }
}

class _SlideGradient extends GradientTransform {
  const _SlideGradient(this.t);
  final double t;

  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(bounds.width * (t * 2 - 1), 0, 0);
}

// ── AgentCoreHero ────────────────────────────────────────────────────────────

/// The Buying Agent before anyone has asked it anything: Zeno in a soft
/// glow with one ring turning round it, what it does, and how - Tell me,
/// I hunt, I recommend. It bursts open once, on arrival, and then breathes.
///
/// 2026-10-10: this was a reactor - a dial of ticks, gauge arcs, a dashed
/// orbit, a comet, bearing marks, six emoji chips circling and a status line
/// typing itself out. With all of it moving at once nothing read as the
/// point, and the screen looked busier than Home rather than of a piece with
/// it. What is left is what says "the agent is on": Zeno, its light, a ring.
class AgentCoreHero extends StatefulWidget {
  const AgentCoreHero({
    super.key,
    required this.subtitle,
    this.title = 'Your Buying Agent',
  });

  final String title;
  final String subtitle;

  static const steps = [
    (Icons.chat_bubble_rounded, 'Tell me'),
    (Icons.radar_rounded, 'I hunt'),
    (Icons.recommend_rounded, 'I recommend'),
  ];

  @override
  State<AgentCoreHero> createState() => _AgentCoreHeroState();
}

class _AgentCoreHeroState extends State<AgentCoreHero> with TickerProviderStateMixin {
  // One slow loop drives everything that drifts. Each part runs at a whole
  // multiple of it, so the loop wraps with no visible jump.
  late final AnimationController _loop =
      AnimationController(vsync: this, duration: const Duration(seconds: 12));
  late final AnimationController _enter =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1400));

  // Built once: a CurvedAnimation subscribes to its parent as it is made,
  // so one made per build is a listener added per rebuild.
  late final _core =
      CurvedAnimation(parent: _enter, curve: const Interval(0.0, 0.75, curve: Curves.elasticOut));
  late final _text =
      CurvedAnimation(parent: _enter, curve: const Interval(0.3, 0.7, curve: Curves.easeOutCubic));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncLoop(_loop, context);
    _playOnce(_enter, context, play: true);
  }

  @override
  void dispose() {
    _core.dispose();
    _text.dispose();
    _loop.dispose();
    _enter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final core = _core;
    final text = _text;
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 18),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          width: 188,
          height: 188,
          child: RepaintBoundary(
            child: Stack(alignment: Alignment.center, children: [
              Positioned.fill(child: CustomPaint(painter: _CorePainter(_loop, _enter))),
              AnimatedBuilder(
                animation: Listenable.merge([_loop, core]),
                builder: (_, child) {
                  final breathe = 1 + 0.03 * math.sin(_loop.value * 2 * math.pi * 6);
                  return Transform.scale(scale: core.value * breathe, child: child);
                },
                child: const ZenoAvatar(size: 92, glow: true),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 6),
        FadeTransition(
          opacity: text,
          child: SlideTransition(
            position: Tween(begin: const Offset(0, 0.4), end: Offset.zero).animate(text),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              ShaderMask(
                blendMode: BlendMode.srcIn,
                shaderCallback: (r) => const LinearGradient(colors: BrokaColors.brandGradient)
                    .createShader(r),
                child: Text(widget.title,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 23, fontWeight: FontWeight.w900, letterSpacing: 0.3)),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Text(widget.subtitle,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: BrokaColors.textMid, fontSize: 13.5, height: 1.45)),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 22),
        _StepsRow(loop: _loop, enter: _enter),
      ]),
    );
  }
}

/// Behind Zeno: a breathing glow, two slow ripples going out, and one thin
/// ring with a light running round it.
class _CorePainter extends CustomPainter {
  _CorePainter(this.loop, this.enter) : super(repaint: Listenable.merge([loop, enter]));

  final Animation<double> loop;
  final Animation<double> enter;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final t = loop.value;
    final e = Curves.easeOutCubic.transform(enter.value.clamp(0.0, 1.0));
    final maxR = size.shortestSide / 2;
    const tau = 2 * math.pi;

    final breathe = 0.5 + 0.5 * math.sin(t * tau * 6);
    canvas.drawCircle(
      c,
      maxR * 0.8,
      Paint()
        ..shader = RadialGradient(colors: [
          _violet.withOpacity((0.32 + 0.08 * breathe) * e),
          _blue.withOpacity(0.12 * e),
          Colors.transparent,
        ], stops: const [0.0, 0.55, 1.0])
            .createShader(Rect.fromCircle(center: c, radius: maxR * 0.8)),
    );

    // Two ripples, one every three seconds, quiet.
    for (var i = 0; i < 2; i++) {
      final p = (t * 2 + i / 2) % 1.0;
      canvas.drawCircle(
        c,
        maxR * 0.55 + p * maxR * 0.45,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.1
          ..color = _cyan.withOpacity((1 - p) * 0.22 * e),
      );
    }

    // The ring, and a light running round it.
    final r = maxR * 0.66;
    final rect = Rect.fromCircle(center: c, radius: r);
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = _violet.withOpacity(0.3 * e),
    );
    final start = (t * 3 % 1.0) * tau - math.pi / 2;
    const sweep = math.pi * 1.1;
    canvas.drawArc(
      rect,
      start,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeCap = StrokeCap.round
        ..shader = SweepGradient(
          colors: [_violet.withOpacity(0), _violet.withOpacity(0.9 * e), _cyan.withOpacity(e)],
          stops: const [0.0, 0.45, sweep / tau],
          transform: GradientRotation(start),
        ).createShader(rect),
    );
    final head = c + Offset(math.cos(start + sweep), math.sin(start + sweep)) * r;
    canvas.drawCircle(head, 5,
        Paint()..color = _cyan.withOpacity(0.5 * e)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
    canvas.drawCircle(head, 2, Paint()..color = Colors.white.withOpacity(e));
  }

  @override
  bool shouldRepaint(_CorePainter old) => old.loop != loop || old.enter != enter;
}

/// Tell me -> I hunt -> I recommend, with a light travelling along the line
/// between them that lights each step as it passes.
class _StepsRow extends StatelessWidget {
  const _StepsRow({required this.loop, required this.enter});

  final Animation<double> loop;
  final Animation<double> enter;

  @override
  Widget build(BuildContext context) {
    const steps = AgentCoreHero.steps;
    return AnimatedBuilder(
      animation: Listenable.merge([loop, enter]),
      builder: (_, __) {
        // The light crosses once every three seconds (four per loop).
        final travel = (loop.value * 4) % 1.0;
        // The steps share the width with the lines between them: at large
        // text on a small phone their labels used to push the row off the
        // screen (101px over at 320dp and 1.3x).
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(children: [
            for (var i = 0; i < steps.length; i++) ...[
              if (i > 0)
                Expanded(child: _Connector(lit: _litBetween(travel, i - 1))),
              Expanded(
                flex: 2,
                child: _Step(
                  icon: steps[i].$1,
                  label: steps[i].$2,
                  glow: _glowAt(travel, i / (steps.length - 1)),
                  appear: Curves.easeOutBack.transform(
                      Interval(0.45 + 0.13 * i, 0.8 + 0.07 * i).transform(enter.value.clamp(0.0, 1.0))),
                ),
              ),
            ],
          ]),
        );
      },
    );
  }

  static double _glowAt(double travel, double at) {
    final d = (travel - at).abs();
    return (1 - d * 4).clamp(0.0, 1.0);
  }

  /// Where the light is along the connector after step [from], 0..1, or
  /// null when it is elsewhere.
  static double? _litBetween(double travel, int from) {
    final local = travel * 2 - from;
    return (local >= 0 && local <= 1) ? local : null;
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.icon, required this.label, required this.glow, required this.appear});

  final IconData icon;
  final String label;
  final double glow;
  final double appear;

  @override
  Widget build(BuildContext context) => Opacity(
        opacity: appear.clamp(0.0, 1.0),
        child: Transform.scale(
          scale: appear,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color.lerp(BrokaColors.bgCard, _violet, 0.25 + 0.55 * glow)!,
                    Color.lerp(BrokaColors.bgCard, _blue, 0.15 + 0.55 * glow)!,
                  ],
                ),
                border: Border.all(color: _cyan.withOpacity(0.25 + 0.6 * glow)),
                boxShadow: [BoxShadow(color: _cyan.withOpacity(0.45 * glow), blurRadius: 16)],
              ),
              child: Icon(icon, size: 19, color: Color.lerp(BrokaColors.textMid, Colors.white, glow)),
            ),
            const SizedBox(height: 6),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(label,
                  maxLines: 1,
                  style: TextStyle(
                      color: Color.lerp(BrokaColors.textMid, BrokaColors.textHigh, glow),
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700)),
            ),
          ]),
        ),
      );
}

class _Connector extends StatelessWidget {
  const _Connector({required this.lit});
  final double? lit;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 20, left: 4, right: 4),
        child: SizedBox(
          height: 2,
          child: CustomPaint(painter: _ConnectorPainter(lit)),
        ),
      );
}

class _ConnectorPainter extends CustomPainter {
  _ConnectorPainter(this.lit);
  final double? lit;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final base = Paint()
      ..color = _violet.withOpacity(0.35)
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    // Dashes, like a route on a map.
    for (double x = 0; x < size.width; x += 7) {
      canvas.drawLine(Offset(x, y), Offset(math.min(x + 3.5, size.width), y), base);
    }
    final l = lit;
    if (l == null) return;
    final x = size.width * l;
    canvas.drawCircle(Offset(x, y), 5,
        Paint()..color = _cyan.withOpacity(0.6)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
    canvas.drawCircle(Offset(x, y), 2, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(_ConnectorPainter old) => old.lit != lit;
}

// ── AgentScanCard ────────────────────────────────────────────────────────────

/// A search in progress, as a radar scope: a beam sweeping the market with
/// a trail of light behind it, rings pulsing out from Zeno at the centre,
/// listings lighting up as the beam passes and brackets locking on to them,
/// a bezel of ticks turning - and under it, what Zeno is doing.
///
/// Purely a show of work - [step] is a timer's, and the card never marks a
/// step as done, because nothing here knows that it is. The blips are not
/// listings it has found, and nothing on the scope is a count.
///
/// 2026-10-10: the scope is the card now, centred and sized to the phone,
/// rather than a thumbnail beside a caption.
class AgentScanCard extends StatefulWidget {
  const AgentScanCard({
    super.key,
    required this.caption,
    required this.step,
    required this.steps,
    this.padding = const EdgeInsets.fromLTRB(16, 4, 16, 8),
  });

  final String caption;
  final int step;
  final int steps;
  final EdgeInsetsGeometry padding;

  @override
  State<AgentScanCard> createState() => _AgentScanCardState();
}

class _AgentScanCardState extends State<AgentScanCard> with TickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 4000));
  late final AnimationController _enter =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 620));
  late final _pop = CurvedAnimation(parent: _enter, curve: Curves.easeOutBack);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncLoop(_c, context);
    _playOnce(_enter, context, play: true);
  }

  @override
  void dispose() {
    _pop.dispose();
    _c.dispose();
    _enter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The scope is the point of the card: as large as a short phone can
    // spare beside the conversation and the composer.
    final scope = (MediaQuery.sizeOf(context).height * 0.19).clamp(104.0, 168.0);
    return Semantics(
      liveRegion: true,
      label: widget.caption,
      child: FadeTransition(
        opacity: _enter,
        child: ScaleTransition(
          scale: Tween(begin: 0.85, end: 1.0).animate(_pop),
          child: Padding(
            padding: widget.padding,
            // The edge turns while the hunt is on.
            child: AgentHoloBorder(
              live: true,
              borderRadius: BorderRadius.circular(22),
              glow: 0.3,
              child: Container(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [BrokaColors.bgCard.withOpacity(0.96), const Color(0xF2070B16)],
                  ),
                  borderRadius: BorderRadius.circular(22),
                  boxShadow: [BoxShadow(color: _cyan.withOpacity(0.16), blurRadius: 24)],
                ),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Row(children: [
                    Icon(Icons.radar_rounded, size: 14, color: _cyan),
                    SizedBox(width: 6),
                    Expanded(
                      child: Text('ZENO IS SCANNING BROKA',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: _cyan, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1.6)),
                    ),
                    SizedBox(width: 8),
                    AgentHudTag('LIVE', color: BrokaColors.success),
                  ]),
                  const SizedBox(height: 10),
                  SizedBox.square(
                    dimension: scope,
                    child: Stack(alignment: Alignment.center, children: [
                      Positioned.fill(child: RepaintBoundary(child: CustomPaint(painter: _ScopePainter(_c)))),
                      ZenoAvatar(size: scope * 0.2, glow: true),
                    ]),
                  ),
                  const SizedBox(height: 10),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 380),
                    transitionBuilder: (child, a) => FadeTransition(
                      opacity: a,
                      child: SlideTransition(
                        position: Tween(begin: const Offset(0, 0.6), end: Offset.zero)
                            .animate(CurvedAnimation(parent: a, curve: Curves.easeOutCubic)),
                        child: child,
                      ),
                    ),
                    layoutBuilder: (current, previous) => Stack(
                        alignment: Alignment.center, children: [...previous, if (current != null) current]),
                    child: AgentShimmerText(
                      widget.caption,
                      key: ValueKey(widget.caption),
                      maxLines: 1,
                      textAlign: TextAlign.center,
                      colors: const [BrokaColors.textHigh, _cyan, Colors.white, _cyan, BrokaColors.textHigh],
                      style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    for (var i = 0; i < widget.steps; i++)
                      AnimatedContainer(
                        duration: BrokaMotion.standard,
                        curve: Curves.easeOutCubic,
                        margin: const EdgeInsets.symmetric(horizontal: 2.5),
                        width: i == widget.step ? 18 : 6,
                        height: 6,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(3),
                          gradient: i == widget.step ? const LinearGradient(colors: [_violet, _cyan]) : null,
                          color: i == widget.step ? null : BrokaColors.border,
                        ),
                      ),
                  ]),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The scope. One loop is two turns of the beam, two pulses out from the
/// centre and a quarter turn of the bezel the other way.
class _ScopePainter extends CustomPainter {
  _ScopePainter(this.a) : super(repaint: a);
  final Animation<double> a;

  // Fixed points on the scope: (angle, distance from the centre as a
  // fraction of the radius). Decoration, not listings.
  static const _blips = [(0.55, 0.74), (1.8, 0.47), (2.75, 0.86), (3.7, 0.32), (4.45, 0.63), (5.5, 0.82)];

  @override
  void paint(Canvas canvas, Size size) {
    const tau = 2 * math.pi;
    final c = size.center(Offset.zero);
    final outer = size.shortestSide / 2 - 1;
    final r = outer * 0.84;
    final rect = Rect.fromCircle(center: c, radius: r);
    final t = a.value;

    // The glass: deep at the rim, lit at the centre.
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = RadialGradient(colors: [
          _cyan.withOpacity(0.18),
          _blue.withOpacity(0.07),
          const Color(0xFF03040A).withOpacity(0.6),
        ], stops: const [0.0, 0.6, 1.0])
            .createShader(rect),
    );

    // Range rings, the crosshair and the diagonals.
    final grid = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8
      ..color = _cyan.withOpacity(0.18);
    for (var i = 1; i <= 4; i++) {
      canvas.drawCircle(c, r * i / 4, grid);
    }
    canvas.drawLine(c.translate(-r, 0), c.translate(r, 0), grid);
    canvas.drawLine(c.translate(0, -r), c.translate(0, r), grid);
    final faint = Paint()
      ..strokeWidth = 0.6
      ..color = _cyan.withOpacity(0.08);
    for (final k in [1, 3, 5, 7]) {
      final dir = Offset(math.cos(k * math.pi / 4), math.sin(k * math.pi / 4));
      canvas.drawLine(c + dir * r * 0.25, c + dir * r, faint);
    }

    // A pulse going out from Zeno, twice a loop.
    for (var i = 0; i < 2; i++) {
      final p = (t * 2 + i / 2) % 1.0;
      canvas.drawCircle(
        c,
        r * (0.2 + 0.8 * Curves.easeOutCubic.transform(p)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6 * (1 - p) + 0.4
          ..color = _violet.withOpacity(0.45 * (1 - p)),
      );
    }

    // The beam: a wedge of light trailing a bright edge.
    final angle = (t * 2 % 1.0) * tau - math.pi / 2;
    const wedge = math.pi * 0.42;
    canvas.save();
    canvas.clipPath(Path()..addOval(rect));
    canvas.drawArc(
      rect,
      angle - wedge,
      wedge,
      true,
      Paint()
        ..shader = SweepGradient(
          colors: [_cyan.withOpacity(0), _cyan.withOpacity(0.12), _cyan.withOpacity(0.5)],
          stops: const [0.0, 0.6, wedge / tau],
          transform: GradientRotation(angle - wedge),
        ).createShader(rect),
    );
    canvas.restore();
    final tip = c + Offset(math.cos(angle), math.sin(angle)) * r;
    canvas.drawLine(
        c,
        tip,
        Paint()
          ..color = _cyan.withOpacity(0.6)
          ..strokeWidth = 4
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
    canvas.drawLine(c, tip, Paint()..color = Colors.white.withOpacity(0.9)..strokeWidth = 1.3);

    // What the beam has just passed lights up, pings, and is locked on to.
    for (final (at, dist) in _blips) {
      final behind = (angle - (at - math.pi / 2)) % tau;
      final glow = (1 - behind / (tau * 0.75)).clamp(0.0, 1.0);
      if (glow <= 0) continue;
      final p = c + Offset(math.cos(at - math.pi / 2), math.sin(at - math.pi / 2)) * r * dist;
      canvas.drawCircle(p, 5,
          Paint()..color = _cyan.withOpacity(0.5 * glow)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
      canvas.drawCircle(p, 1.9, Paint()..color = Colors.white.withOpacity(glow));
      if (glow > 0.7) {
        final k = (glow - 0.7) / 0.3;
        canvas.drawCircle(
          p,
          4 + 10 * (1 - k),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = _cyan.withOpacity(0.7 * k),
        );
        final s = 8.0 - 3 * k;
        final bracket = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.1
          ..color = Colors.white.withOpacity(0.85 * k);
        for (final (dx, dy) in [(-1.0, -1.0), (1.0, -1.0), (-1.0, 1.0), (1.0, 1.0)]) {
          final corner = p + Offset(dx * s, dy * s);
          canvas.drawLine(corner, corner - Offset(dx * 3, 0), bracket);
          canvas.drawLine(corner, corner - Offset(0, dy * 3), bracket);
        }
      }
    }

    // The rim, and a bezel of ticks turning slowly the other way.
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4
        ..color = _cyan.withOpacity(0.45),
    );
    final turn = -t * tau / 4;
    final tick = Paint()..strokeCap = StrokeCap.round;
    for (var k = 0; k < 72; k++) {
      final ang = turn + k * tau / 72;
      final long = k % 6 == 0;
      tick
        ..strokeWidth = long ? 1.4 : 0.9
        ..color = (long ? _cyan : _violet).withOpacity(long ? 0.75 : 0.4);
      final dir = Offset(math.cos(ang), math.sin(ang));
      canvas.drawLine(c + dir * (outer - (long ? 7 : 4)), c + dir * outer, tick);
    }

    // Two arcs of the HUD between the scope and the bezel, turning apart.
    final hud = Rect.fromCircle(center: c, radius: (r + outer - 8) / 2 + 1);
    for (final (start, sweep, color, speed) in [
      (0.3, 0.9, _violet, 1.0),
      (3.4, 0.6, _cyan, -1.0),
    ]) {
      canvas.drawArc(
        hud,
        start + speed * t * tau,
        sweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2
          ..strokeCap = StrokeCap.round
          ..color = color.withOpacity(0.7),
      );
    }
  }

  @override
  bool shouldRepaint(_ScopePainter old) => old.a != a;
}

// ── AgentBriefStrip ──────────────────────────────────────────────────────────

/// What Zeno has understood so far - the item, the budget, the condition,
/// the specs - as a row of chips under the header. The criteria used to be
/// invisible until a search came back wrong; now a misheard budget is on
/// screen the moment Zeno mishears it. Each chip pops in when Zeno learns
/// it, and pops again when it changes.
class AgentBriefStrip extends StatelessWidget {
  const AgentBriefStrip({super.key, required this.slots});

  final Map<String, dynamic> slots;

  /// (id, icon, label) for each thing Zeno knows, in the order a buyer
  /// would say them.
  static List<(String, IconData, String)> chipsFor(Map<String, dynamic> slots) {
    String? text(String k) {
      final v = slots[k];
      return v is String && v.trim().isNotEmpty ? v.trim() : null;
    }

    num? amount(String k) {
      final v = slots[k];
      return v is num && v > 0 ? v : null;
    }

    final chips = <(String, IconData, String)>[];
    if (text('query') case final q?) chips.add(('query', Icons.search_rounded, q));
    if (text('category') case final cat?) {
      final sub = text('subcategory');
      chips.add(('category', Icons.sell_rounded, sub == null ? cat : '$cat › $sub'));
    }
    final lo = amount('min_price');
    final hi = amount('max_price');
    if (lo != null || hi != null) {
      final label = switch ((lo, hi)) {
        (final l?, final h?) => '${formatKes(l)} – ${formatKesAmount(h)}',
        (null, final h?) => 'Under ${formatKes(h)}',
        (final l?, null) => 'From ${formatKes(l)}',
        _ => '',
      };
      chips.add(('budget', Icons.payments_rounded, label));
    }
    if (text('condition') case final c?) {
      chips.add(('condition', Icons.auto_awesome_rounded, c[0].toUpperCase() + c.substring(1)));
    }
    final place = text('location');
    final km = amount('max_distance_km');
    if (place != null || km != null) {
      final within = km == null ? null : 'within ${km.round()} km';
      chips.add(('where', Icons.place_rounded,
          [if (place != null) place, if (within != null) within].join(' · ')));
    }
    final attrs = slots['attributes'];
    if (attrs is Map) {
      for (final e in attrs.entries) {
        final v = e.value?.toString().trim() ?? '';
        if (v.isEmpty) continue;
        chips.add(('attr:${e.key}', Icons.tune_rounded, '${e.key}: $v'));
      }
    }
    return chips;
  }

  @override
  Widget build(BuildContext context) {
    final chips = chipsFor(slots);
    if (chips.isEmpty) return const SizedBox(width: double.infinity);
    // Full width: a sideways scroller is only as wide as what it holds, and
    // a short brief would sit centred under the header instead of at its
    // left edge.
    return SizedBox(
      width: double.infinity,
      height: 40,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
        child: Row(children: [
          const Padding(
            padding: EdgeInsets.only(right: 8),
            child: AgentHudTag('BRIEF'),
          ),
          for (var i = 0; i < chips.length; i++)
            _BriefChip(
              key: ValueKey('${chips[i].$1}=${chips[i].$3}'),
              icon: chips[i].$2,
              label: chips[i].$3,
              index: i,
            ),
        ]),
      ),
    );
  }
}

class _BriefChip extends StatefulWidget {
  const _BriefChip({super.key, required this.icon, required this.label, required this.index});

  final IconData icon;
  final String label;
  final int index;

  @override
  State<_BriefChip> createState() => _BriefChipState();
}

class _BriefChipState extends State<_BriefChip> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
  // A small stagger, so a turn that teaches Zeno four things lands as four
  // pops rather than one. Fixed at the chip's first build.
  late final double _delay = (widget.index * 0.06).clamp(0.0, 0.4);
  late final _pop =
      CurvedAnimation(parent: _c, curve: Interval(_delay, 1.0, curve: Curves.elasticOut));
  late final _flash =
      CurvedAnimation(parent: _c, curve: Interval(_delay, 1.0, curve: Curves.easeOut));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _playOnce(_c, context, play: true);
  }

  @override
  void dispose() {
    _pop.dispose();
    _flash.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pop = _pop;
    final flash = _flash;
    return AnimatedBuilder(
      animation: _c,
      builder: (_, child) => Opacity(
        opacity: (pop.value * 4).clamp(0.0, 1.0),
        child: Transform.scale(scale: 0.3 + 0.7 * pop.value, child: Container(
          margin: const EdgeInsets.only(right: 6),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: Color.lerp(BrokaColors.bgCard, _violet, 0.35 * (1 - flash.value))!.withOpacity(0.92),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Color.lerp(_cyan, _violet.withOpacity(0.45), flash.value)!),
            boxShadow: [BoxShadow(color: _cyan.withOpacity(0.5 * (1 - flash.value)), blurRadius: 12)],
          ),
          child: child,
        )),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(widget.icon, size: 12, color: _cyan),
        const SizedBox(width: 5),
        Text(widget.label,
            style: const TextStyle(
                color: BrokaColors.textHigh, fontSize: 11.5, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

// ── AgentMatchCarousel ───────────────────────────────────────────────────────

/// A search's results as cards to swipe through, not a column of them down
/// the conversation: the verdict and the count on top, the cards turning in
/// 3D as they move, and - when the results are new - dealt in from the
/// right one after another.
class AgentMatchCarousel extends StatefulWidget {
  const AgentMatchCarousel({
    super.key,
    required this.count,
    required this.exact,
    required this.itemBuilder,
    this.dealIn = false,
    this.itemHeight = 312,
  });

  final int count;

  /// How many of them match everything asked for.
  final int exact;
  final IndexedWidgetBuilder itemBuilder;
  final bool dealIn;
  final double itemHeight;

  /// "2 exact matches", "3 close options", "1 exact · 2 close".
  static String verdictLabel(int count, int exact) {
    String plural(int n, String one, String many) => n == 1 ? one : many;
    if (exact == count) return '$count exact ${plural(count, 'match', 'matches')}';
    if (exact == 0) return '$count close ${plural(count, 'option', 'options')}';
    return '$exact exact · ${count - exact} close';
  }

  @override
  State<AgentMatchCarousel> createState() => _AgentMatchCarouselState();
}

class _AgentMatchCarouselState extends State<AgentMatchCarousel>
    with SingleTickerProviderStateMixin {
  final _pages = PageController(viewportFraction: 0.86);
  late final AnimationController _deal =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));
  late final _badgePop =
      CurvedAnimation(parent: _deal, curve: const Interval(0.0, 0.5, curve: Curves.elasticOut));
  int _page = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _playOnce(_deal, context, play: widget.dealIn);
  }

  @override
  void dispose() {
    _badgePop.dispose();
    _pages.dispose();
    _deal.dispose();
    super.dispose();
  }

  double get _position {
    if (_pages.hasClients && _pages.position.haveDimensions) return _pages.page ?? 0;
    return _page.toDouble();
  }

  @override
  Widget build(BuildContext context) {
    final allExact = widget.exact == widget.count;
    final tone = allExact ? BrokaColors.success : (widget.exact > 0 ? _cyan : BrokaColors.gold);
    final still = BrokaMotion.reduced(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(children: [
          _VerdictBadge(
            label: AgentMatchCarousel.verdictLabel(widget.count, widget.exact),
            icon: allExact ? Icons.verified_rounded : Icons.travel_explore_rounded,
            tone: tone,
            pop: _badgePop,
          ),
          const Spacer(),
          if (widget.count > 1)
            AnimatedSwitcher(
              duration: BrokaMotion.quick,
              transitionBuilder: (c, a) => ScaleTransition(scale: a, child: FadeTransition(opacity: a, child: c)),
              child: Text('${_page + 1} / ${widget.count}',
                  key: ValueKey(_page),
                  style: const TextStyle(
                      color: BrokaColors.textMid, fontSize: 11.5, fontWeight: FontWeight.w700)),
            ),
        ]),
      ),
      SizedBox(
        height: widget.itemHeight,
        // Cards keep to a readable size however large the system text is:
        // they are fixed-height pages, and a card that grows past its page
        // is cut off rather than scrolled.
        child: MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1.3,
          child: PageView.builder(
            controller: _pages,
            padEnds: false,
            itemCount: widget.count,
            onPageChanged: (i) => setState(() => _page = i),
            itemBuilder: (context, i) {
              // Each result locked on as it is dealt: brackets closing on
              // it in the verdict's colour.
              final card = Padding(
                padding: const EdgeInsets.fromLTRB(6, 6, 18, 6),
                child: AgentLockOn(
                  tone: tone,
                  play: widget.dealIn,
                  child: widget.itemBuilder(context, i),
                ),
              );
              if (still) return card;
              return AnimatedBuilder(
                animation: Listenable.merge([_pages, _deal]),
                child: card,
                builder: (_, child) {
                  // Coverflow: a card turns away and shrinks as it leaves.
                  final d = (_position - i).clamp(-1.0, 1.0);
                  // Dealt in from the right, one after another.
                  final start = (i * 0.14).clamp(0.0, 0.5);
                  final dealt = Curves.easeOutBack.transform(
                      Interval(start, (start + 0.55).clamp(0.0, 1.0)).transform(_deal.value));
                  final m = Matrix4.identity()
                    ..setEntry(3, 2, 0.0012)
                    ..translate(260 * (1 - dealt), 0.0, 0.0)
                    ..rotateZ(0.14 * (1 - dealt))
                    ..rotateY(d * 0.45)
                    ..scale(1 - 0.10 * d.abs());
                  return Opacity(
                    opacity: ((1 - 0.35 * d.abs()) * dealt.clamp(0.0, 1.0)).clamp(0.0, 1.0),
                    child: Transform(alignment: Alignment.center, transform: m, child: child),
                  );
                },
              );
            },
          ),
        ),
      ),
      if (widget.count > 1)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(children: [
            for (var i = 0; i < widget.count; i++)
              AnimatedContainer(
                duration: BrokaMotion.standard,
                curve: Curves.easeOutCubic,
                margin: const EdgeInsets.only(right: 5),
                width: i == _page ? 20 : 6,
                height: 6,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(3),
                  gradient: i == _page ? const LinearGradient(colors: [_violet, _cyan]) : null,
                  color: i == _page ? null : BrokaColors.border,
                ),
              ),
          ]),
        ),
    ]);
  }
}

class _VerdictBadge extends StatelessWidget {
  const _VerdictBadge({required this.label, required this.icon, required this.tone, required this.pop});

  final String label;
  final IconData icon;
  final Color tone;
  final Animation<double> pop;

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: pop,
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: tone.withOpacity(0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: tone.withOpacity(0.55)),
          boxShadow: [BoxShadow(color: tone.withOpacity(0.25), blurRadius: 12)],
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: tone),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(color: tone, fontSize: 12, fontWeight: FontWeight.w800)),
        ]),
      ),
    );
  }
}

// ── AgentActionButton ────────────────────────────────────────────────────────

/// A card's call to action: a gradient pill with light running across it,
/// that shrinks under a finger. [done] turns it green and still.
class AgentActionButton extends StatefulWidget {
  const AgentActionButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
    this.busy = false,
    this.done = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final bool busy;
  final bool done;

  @override
  State<AgentActionButton> createState() => _AgentActionButtonState();
}

class _AgentActionButtonState extends State<AgentActionButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shine =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 3000));
  bool _down = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncLoop(_shine, context);
  }

  @override
  void dispose() {
    _shine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null && !widget.busy;
    final colors = widget.done
        ? [BrokaColors.success.withOpacity(0.18), BrokaColors.success.withOpacity(0.10)]
        : [_violet.withOpacity(0.85), _blue.withOpacity(0.85)];
    final fg = widget.done ? BrokaColors.success : Colors.white;
    return Semantics(
      button: true,
      label: widget.label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? widget.onTap : null,
        onTapDown: enabled ? (_) => setState(() => _down = true) : null,
        onTapUp: enabled ? (_) => setState(() => _down = false) : null,
        onTapCancel: enabled ? () => setState(() => _down = false) : null,
        child: AnimatedScale(
          scale: _down && !BrokaMotion.reduced(context) ? 0.95 : 1.0,
          duration: BrokaMotion.instant,
          child: Container(
            height: 40,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              gradient: LinearGradient(colors: colors),
              border: widget.done ? Border.all(color: BrokaColors.success.withOpacity(0.5)) : null,
              boxShadow: widget.done
                  ? null
                  : [BoxShadow(color: _blue.withOpacity(0.30), blurRadius: 12, offset: const Offset(0, 3))],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Stack(alignment: Alignment.center, children: [
                if (!widget.done)
                  Positioned.fill(
                    child: RepaintBoundary(child: CustomPaint(painter: _ShinePainter(_shine))),
                  ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (widget.busy)
                        SizedBox(
                            width: 15,
                            height: 15,
                            child: CircularProgressIndicator(strokeWidth: 2, color: fg))
                      else
                        Icon(widget.icon, size: 16, color: fg),
                      const SizedBox(width: 7),
                      Text(widget.label,
                          style: TextStyle(color: fg, fontSize: 12.5, fontWeight: FontWeight.w700)),
                    ]),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// A diagonal band of light that crosses once near the start of each loop
/// and then rests, so it reads as a glint rather than a flicker.
class _ShinePainter extends CustomPainter {
  _ShinePainter(this.a, {this.strength = 0.22, this.window = 0.28}) : super(repaint: a);
  final Animation<double> a;
  final double strength;

  /// The part of the loop the band spends crossing.
  final double window;

  @override
  void paint(Canvas canvas, Size size) {
    final t = a.value / window;
    if (t >= 1) return;
    final p = Curves.easeInOut.transform(t);
    final w = size.height * 1.6;
    final x = -w + (size.width + w * 2) * p;
    final band = Rect.fromLTWH(x - w, 0, w * 2, size.height);
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            Colors.white.withOpacity(0),
            Colors.white.withOpacity(strength),
            Colors.white.withOpacity(0),
          ],
          transform: const GradientRotation(-0.35),
        ).createShader(band),
    );
  }

  @override
  bool shouldRepaint(_ShinePainter old) => old.a != a;
}

/// A glint crossing [child] every [period] - for Home's Zeno CTA.
class AgentShine extends StatefulWidget {
  const AgentShine({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(16)),
    this.period = const Duration(seconds: 6),
  });

  final Widget child;
  final BorderRadius borderRadius;
  final Duration period;

  @override
  State<AgentShine> createState() => _AgentShineState();
}

class _AgentShineState extends State<AgentShine> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: widget.period);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncLoop(_c, context);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CustomPaint(
        foregroundPainter: BrokaMotion.reduced(context)
            ? null
            : _ClippedShinePainter(_c, widget.borderRadius),
        child: widget.child,
      );
}

class _ClippedShinePainter extends _ShinePainter {
  _ClippedShinePainter(super.a, this.radius) : super(strength: 0.10, window: 0.2);
  final BorderRadius radius;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRRect(radius.toRRect(Offset.zero & size));
    super.paint(canvas, size);
    canvas.restore();
  }
}

// ── AgentWatchOffer ──────────────────────────────────────────────────────────

/// The offer to keep watching, and the watch once it is running. Switching
/// from one to the other is the moment the agent goes to work on its own,
/// so it flips over with a burst rather than swapping a line of text.
class AgentWatchOffer extends StatelessWidget {
  const AgentWatchOffer({
    super.key,
    required this.watching,
    required this.busy,
    required this.onWatch,
    this.celebrate = false,
  });

  final bool watching;
  final bool busy;
  final VoidCallback onWatch;

  /// The watch has just been set (not restored): burst as it turns on.
  final bool celebrate;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
        duration: BrokaMotion.of(context, const Duration(milliseconds: 520)),
        switchInCurve: Curves.easeOutBack,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, a) => FadeTransition(
          opacity: a,
          child: ScaleTransition(scale: Tween(begin: 0.8, end: 1.0).animate(a), child: child),
        ),
        layoutBuilder: (current, previous) => Stack(
            alignment: Alignment.topLeft, children: [...previous, if (current != null) current]),
        child: watching
            ? _WatchOn(key: const ValueKey('on'), celebrate: celebrate)
            : _WatchOffer(key: const ValueKey('offer'), busy: busy, onWatch: onWatch),
      );
}

class _WatchOffer extends StatelessWidget {
  const _WatchOffer({super.key, required this.busy, required this.onWatch});

  final bool busy;
  final VoidCallback onWatch;

  @override
  Widget build(BuildContext context) => Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: busy ? null : onWatch,
          borderRadius: BorderRadius.circular(16),
          child: Ink(
            padding: const EdgeInsets.fromLTRB(10, 10, 14, 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [_violet.withOpacity(0.20), _blue.withOpacity(0.10)],
              ),
              border: Border.all(color: _violet.withOpacity(0.5)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const AgentOrb(size: 26, pings: true),
              const SizedBox(width: 10),
              const Flexible(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text('Keep watching for me',
                      style: TextStyle(color: BrokaColors.textHigh, fontSize: 13.5, fontWeight: FontWeight.w800)),
                  SizedBox(height: 2),
                  Text("I'll tell you the moment something new fits.",
                      style: TextStyle(color: BrokaColors.textMid, fontSize: 11.5)),
                ]),
              ),
              const SizedBox(width: 10),
              busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: _violet))
                  : const Icon(Icons.visibility_rounded, size: 18, color: _violet),
            ]),
          ),
        ),
      );
}

class _WatchOn extends StatefulWidget {
  const _WatchOn({super.key, required this.celebrate});
  final bool celebrate;

  @override
  State<_WatchOn> createState() => _WatchOnState();
}

class _WatchOnState extends State<_WatchOn> with SingleTickerProviderStateMixin {
  late final AnimationController _burst =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 900));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _playOnce(_burst, context, play: widget.celebrate);
  }

  @override
  void dispose() {
    _burst.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(10, 10, 14, 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: BrokaColors.success.withOpacity(0.10),
          border: Border.all(color: BrokaColors.success.withOpacity(0.45)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            width: 36,
            height: 36,
            child: Stack(alignment: Alignment.center, clipBehavior: Clip.none, children: [
              Positioned.fill(
                  child: IgnorePointer(child: CustomPaint(painter: _BurstPainter(_burst)))),
              const AgentOrb(size: 26, pings: true),
            ]),
          ),
          const SizedBox(width: 10),
          const Flexible(
            child: Text("I'll keep watching and tell you when something turns up.",
                style: TextStyle(color: BrokaColors.success, fontSize: 12.5, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: 8),
          const _LivePill(),
        ]),
      );
}

/// "LIVE", with its dot breathing.
class _LivePill extends StatefulWidget {
  const _LivePill();

  @override
  State<_LivePill> createState() => _LivePillState();
}

class _LivePillState extends State<_LivePill> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncLoop(_c, context, reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: BrokaColors.success.withOpacity(0.18),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          FadeTransition(
            opacity: Tween(begin: 0.35, end: 1.0).animate(_c),
            child: Container(
              width: 6,
              height: 6,
              decoration: const BoxDecoration(shape: BoxShape.circle, color: BrokaColors.success),
            ),
          ),
          const SizedBox(width: 4),
          const Text('LIVE',
              style: TextStyle(
                  color: BrokaColors.success, fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 1)),
        ]),
      );
}

/// Sparks thrown out in a ring from the centre, once.
class _BurstPainter extends CustomPainter {
  _BurstPainter(this.a) : super(repaint: a);
  final Animation<double> a;

  static const _colors = [BrokaColors.success, _cyan, _violet, Colors.white];

  @override
  void paint(Canvas canvas, Size size) {
    final t = a.value;
    if (t <= 0 || t >= 1) return;
    final c = size.center(Offset.zero);
    final out = Curves.easeOutCubic.transform(t);
    const n = 14;
    for (var i = 0; i < n; i++) {
      final angle = 2 * math.pi * i / n;
      final dist = 14 + out * (26 + (i % 3) * 8);
      final p = c + Offset(math.cos(angle), math.sin(angle)) * dist;
      canvas.drawCircle(p, 2.4 * (1 - t) + 0.6, Paint()..color = _colors[i % _colors.length].withOpacity(1 - t));
    }
    canvas.drawCircle(
      c,
      14 + out * 30,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 * (1 - t)
        ..color = BrokaColors.success.withOpacity(0.7 * (1 - t)),
    );
  }

  @override
  bool shouldRepaint(_BurstPainter old) => old.a != a;
}

// ── AgentConfetti ────────────────────────────────────────────────────────────

/// Confetti over the whole screen, fired each time [burst] goes up: an exact
/// match found, a watch set. Never takes a tap.
class AgentConfetti extends StatefulWidget {
  const AgentConfetti({super.key, required this.burst});

  final int burst;

  @override
  State<AgentConfetti> createState() => _AgentConfettiState();
}

class _AgentConfettiState extends State<AgentConfetti> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2200));
  final _rnd = math.Random();
  List<_Confetto> _pieces = const [];

  @override
  void didUpdateWidget(AgentConfetti old) {
    super.didUpdateWidget(old);
    if (widget.burst > old.burst && !BrokaMotion.reduced(context)) {
      _pieces = List.generate(90, (_) => _Confetto.random(_rnd));
      _c.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: RepaintBoundary(
          child: CustomPaint(painter: _ConfettiPainter(_c, _pieces), size: Size.infinite),
        ),
      );
}

class _Confetto {
  _Confetto(this.x, this.vx, this.vy, this.spin, this.size, this.color, this.round);

  factory _Confetto.random(math.Random r) => _Confetto(
        0.5 + (r.nextDouble() - 0.5) * 0.3,
        (r.nextDouble() - 0.5) * 1.3,
        -(0.7 + r.nextDouble() * 0.9),
        (r.nextDouble() - 0.5) * 18,
        4 + r.nextDouble() * 5,
        const [_violet, _blue, _cyan, BrokaColors.neonPink, BrokaColors.success, Colors.white][r.nextInt(6)],
        r.nextBool(),
      );

  /// Launch point across the width, as a fraction.
  final double x;

  /// Launch velocity, in screen-widths (x) and screen-heights (y) a second.
  final double vx;
  final double vy;
  final double spin;
  final double size;
  final Color color;
  final bool round;
}

class _ConfettiPainter extends CustomPainter {
  _ConfettiPainter(this.a, this.pieces) : super(repaint: a);

  final Animation<double> a;
  final List<_Confetto> pieces;

  @override
  void paint(Canvas canvas, Size size) {
    final t = a.value;
    if (t <= 0 || t >= 1 || pieces.isEmpty) return;
    final secs = t * 2.2;
    final fade = t < 0.75 ? 1.0 : (1 - (t - 0.75) / 0.25);
    for (final p in pieces) {
      // Thrown up from the lower middle of the screen, then falling.
      final x = (p.x + p.vx * secs * 0.55) * size.width;
      final y = (0.62 + p.vy * secs + 0.9 * secs * secs) * size.height;
      final paint = Paint()..color = p.color.withOpacity(fade.clamp(0.0, 1.0));
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(p.spin * secs);
      if (p.round) {
        canvas.drawCircle(Offset.zero, p.size / 2, paint);
      } else {
        canvas.drawRect(Rect.fromCenter(center: Offset.zero, width: p.size, height: p.size * 0.5), paint);
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ConfettiPainter old) => old.a != a || old.pieces != pieces;
}

// ── AgentEntrance ────────────────────────────────────────────────────────────

/// A bubble arriving: the buyer's springs up from the composer, Zeno's
/// slides in from its avatar. Plays once, when [play] is true as the bubble
/// is first built - a conversation picked up again is simply there.
class AgentEntrance extends StatefulWidget {
  const AgentEntrance({super.key, required this.child, required this.play, required this.fromUser});

  final Widget child;
  final bool play;
  final bool fromUser;

  @override
  State<AgentEntrance> createState() => _AgentEntranceState();
}

class _AgentEntranceState extends State<AgentEntrance> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 560));
  late final _curve = CurvedAnimation(
      parent: _c, curve: widget.fromUser ? Curves.easeOutBack : Curves.easeOutCubic);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _playOnce(_c, context, play: widget.play);
  }

  @override
  void dispose() {
    _curve.dispose();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The same three wrappers before, during and after: returning the bare
    // child once finished would give it a new place in the tree, and a
    // reply still being written would start again from nothing.
    return AnimatedBuilder(
      animation: _c,
      child: widget.child,
      builder: (_, child) {
        final v = _c.isCompleted ? 1.0 : _curve.value;
        final offset = widget.fromUser ? Offset(18 * (1 - v), 30 * (1 - v)) : Offset(-26 * (1 - v), 6 * (1 - v));
        return Opacity(
          opacity: _c.isCompleted ? 1.0 : _c.value.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: offset,
            child: Transform.scale(
              scale: widget.fromUser ? 0.6 + 0.4 * v : 0.94 + 0.06 * v,
              alignment: widget.fromUser ? Alignment.bottomRight : Alignment.topLeft,
              child: child,
            ),
          ),
        );
      },
    );
  }
}

// ── AgentLiveEdge ────────────────────────────────────────────────────────────

/// A light running round the edge of Zeno's bubble while the reply is being
/// written. The painter comes and goes; the child's place in the tree does
/// not, so the text being written keeps its state.
class AgentLiveEdge extends StatefulWidget {
  const AgentLiveEdge({super.key, required this.active, required this.borderRadius, required this.child});

  final bool active;
  final BorderRadius borderRadius;
  final Widget child;

  @override
  State<AgentLiveEdge> createState() => _AgentLiveEdgeState();
}

class _AgentLiveEdgeState extends State<AgentLiveEdge> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));

  bool get _running => widget.active && !BrokaMotion.reduced(context);

  void _sync() {
    if (_running) {
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
  void didUpdateWidget(AgentLiveEdge old) {
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
        foregroundPainter: _running ? _EdgePainter(_c, widget.borderRadius) : null,
        child: widget.child,
      );
}

class _EdgePainter extends CustomPainter {
  _EdgePainter(this.a, this.radius) : super(repaint: a);
  final Animation<double> a;
  final BorderRadius radius;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRRect(
      radius.toRRect(rect).deflate(0.6),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..shader = SweepGradient(
          colors: [
            _violet.withOpacity(0.0),
            _violet.withOpacity(0.0),
            _cyan,
            _violet.withOpacity(0.0),
          ],
          stops: const [0.0, 0.55, 0.8, 1.0],
          transform: GradientRotation(a.value * 2 * math.pi),
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_EdgePainter old) => old.a != a || old.radius != radius;
}
