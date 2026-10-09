// Zeno's tour of BROKA, on screen (zeno_tour.dart has the script and the
// moves): drawn by the session host above every screen.
//
//   welcome  full screen: Zeno's orb speaking, what it does, and the
//            choice - "Show me around" or "Maybe later";
//   step     a card over the screen Zeno has just opened: where this is,
//            what Zeno is saying, how far along the tour is (the current
//            segment fills while it waits to move on), Back and Next;
//   demo     the same card asking what the user would love to buy - typed,
//            tapped from the ideas, or said;
//   finale   a short card and confetti.
//
// Every part of it can be done with a tap; voice only makes it quicker.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../main.dart' show BrokaColors, ZoneGlowText;
import '../../../theme/motion.dart';
import '../../../widgets/zeno_streaming_text.dart';
import '../../buy_agent/presentation/widgets/agent_motion.dart' show AgentConfetti, AgentShimmerText;
import '../zeno_session.dart';
import '../zeno_tour.dart';
import 'zeno_orb.dart';

class ZenoTourLayer extends StatelessWidget {
  const ZenoTourLayer({super.key, required this.session});

  final ZenoSession session;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: Listenable.merge([session, session.tour]),
        builder: (context, _) {
          final tour = session.tour;
          final mq = MediaQuery.of(context);
          final keyboard = mq.viewInsets.bottom;
          // Above a bottom navigation bar, or the keyboard - and above
          // Zeno's pill when it is docked at the bottom.
          var bottom = keyboard > 0 ? keyboard + 10 : mq.padding.bottom + 78;
          if (session.docked && !session.pillAtTop && keyboard == 0) bottom += 74;
          final card = switch (tour.phase) {
            ZenoTourPhase.step || ZenoTourPhase.demo || ZenoTourPhase.finale =>
              _TourCard(key: const ValueKey('zeno-tour-card'), session: session),
            _ => null,
          };
          // After the demo the Buying Agent is hunting below: its composer
          // is at the bottom, so the last card goes at the top - as do the
          // steps about what is at the bottom or the edge.
          final atTop = (tour.phase == ZenoTourPhase.finale && tour.demoRan) || (tour.step?.cardAtTop ?? false);
          return Stack(fit: StackFit.expand, children: [
            AnimatedPositioned(
              duration: BrokaMotion.of(context, BrokaMotion.standard),
              curve: BrokaMotion.enter,
              left: 12,
              right: 12,
              top: atTop ? mq.padding.top + 66 : null,
              bottom: atTop ? null : bottom,
              child: Align(
                alignment: atTop ? Alignment.topCenter : Alignment.bottomCenter,
                heightFactor: 1,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 460),
                  child: AnimatedSwitcher(
                    duration: BrokaMotion.of(context, const Duration(milliseconds: 420)),
                    switchInCurve: Curves.easeOutBack,
                    switchOutCurve: BrokaMotion.exit,
                    transitionBuilder: (c, a) => FadeTransition(
                      opacity: a,
                      child: ScaleTransition(
                        scale: Tween(begin: 0.85, end: 1.0).animate(a),
                        alignment: atTop ? Alignment.topCenter : Alignment.bottomCenter,
                        child: c,
                      ),
                    ),
                    child: card ?? const SizedBox(key: ValueKey('none'), width: double.infinity),
                  ),
                ),
              ),
            ),
            Positioned.fill(child: AgentConfetti(burst: tour.burst)),
            if (tour.phase == ZenoTourPhase.welcome)
              Positioned.fill(child: _Welcome(key: const ValueKey('zeno-tour-welcome'), session: session)),
          ]);
        },
      );
}

// ── Welcome ──────────────────────────────────────────────────────────────────

class _Welcome extends StatefulWidget {
  const _Welcome({super.key, required this.session});

  final ZenoSession session;

  @override
  State<_Welcome> createState() => _WelcomeState();
}

class _WelcomeState extends State<_Welcome> with SingleTickerProviderStateMixin {
  late final AnimationController _in =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1500));
  late final _reveal = CurvedAnimation(parent: _in, curve: const Interval(0, 0.5, curve: Curves.easeOutCubic));
  late final _rise = CurvedAnimation(parent: _in, curve: const Interval(0.3, 0.9, curve: Curves.easeOutCubic));

  static const _powers = [
    (Icons.radar_rounded, 'Finds anything'),
    (Icons.handshake_rounded, 'Negotiates for you'),
    (Icons.visibility_rounded, 'Keeps watch'),
    (Icons.graphic_eq_rounded, 'Talks & takes you there'),
  ];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_in.isAnimating || _in.isCompleted) return;
    if (BrokaMotion.reduced(context)) {
      _in.value = 1;
    } else {
      _in.forward();
    }
  }

  @override
  void dispose() {
    _reveal.dispose();
    _rise.dispose();
    _in.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tour = widget.session.tour;
    return Material(
      type: MaterialType.transparency,
      child: AnimatedBuilder(
        animation: _in,
        builder: (context, child) => ClipPath(
          clipper: _CircleReveal(_reveal.value),
          child: child,
        ),
        child: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0, -0.25),
              radius: 1.15,
              colors: [Color(0xFC1A0E40), Color(0xFD070B16), Color(0xFF03040A)],
              stops: [0.0, 0.55, 1.0],
            ),
          ),
          child: SafeArea(
            child: LayoutBuilder(builder: (context, box) {
              final orb = math.min(box.maxWidth * 0.62, box.maxHeight * 0.32).clamp(96.0, 250.0);
              return SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: box.maxHeight),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 14),
                    child: Column(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                      Column(children: [
                        const SizedBox(height: 6),
                        const ZoneGlowText('Meet Zeno',
                            gradient: [BrokaColors.neonPurple, BrokaColors.neonCyan],
                            fontSize: 22,
                            textAlign: TextAlign.center,
                            maxLines: 1,
                            letterSpacing: 3),
                        const SizedBox(height: 4),
                        const Text('YOUR PERSONAL AI BROKER',
                            style: TextStyle(
                                color: BrokaColors.textMid,
                                fontSize: 10.5,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 2.2)),
                        const SizedBox(height: 14),
                        ZenoOrb(
                          mode: tour.speaking ? ZenoOrbMode.speaking : ZenoOrbMode.listening,
                          level: tour.speaking ? 0.35 : 0.1,
                          size: orb,
                        ),
                      ]),
                      FadeTransition(
                        opacity: _rise,
                        child: SlideTransition(
                          position: Tween(begin: const Offset(0, 0.25), end: Offset.zero).animate(_rise),
                          child: Column(children: [
                            const SizedBox(height: 12),
                            ZenoStreamingText(
                              tour.line,
                              key: ValueKey(tour.line),
                              style: const TextStyle(color: BrokaColors.textHigh, fontSize: 16.5, height: 1.45),
                            ),
                            const SizedBox(height: 16),
                            Wrap(
                              alignment: WrapAlignment.center,
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final (i, p) in _powers.indexed) _Power(icon: p.$1, label: p.$2, index: i),
                              ],
                            ),
                            const SizedBox(height: 22),
                            _GlowButton(
                              key: const Key('zeno-tour-start'),
                              label: 'Show me around',
                              icon: Icons.auto_awesome_rounded,
                              onTap: tour.begin,
                            ),
                            const SizedBox(height: 6),
                            TextButton(
                              key: const Key('zeno-tour-later'),
                              onPressed: tour.decline,
                              child: const Text('Maybe later',
                                  style: TextStyle(color: BrokaColors.textMid, fontWeight: FontWeight.w700)),
                            ),
                          ]),
                        ),
                      ),
                    ]),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

class _CircleReveal extends CustomClipper<Path> {
  _CircleReveal(this.t);
  final double t;

  @override
  Path getClip(Size size) {
    final c = size.center(Offset.zero);
    final far = math.sqrt(c.dx * c.dx + c.dy * c.dy);
    return Path()..addOval(Rect.fromCircle(center: c, radius: 24 + (far - 24) * t));
  }

  @override
  bool shouldReclip(_CircleReveal old) => old.t != t;
}

/// One thing Zeno does, popping in after the one before.
class _Power extends StatelessWidget {
  const _Power({required this.icon, required this.label, required this.index});

  final IconData icon;
  final String label;
  final int index;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: BrokaMotion.of(context, Duration(milliseconds: 700 + 140 * index)),
        curve: Interval((0.3 + 0.12 * index).clamp(0.0, 0.8), 1, curve: Curves.easeOutBack),
        builder: (_, v, child) => Opacity(
          opacity: v.clamp(0.0, 1.0),
          child: Transform.scale(scale: 0.6 + 0.4 * v, child: child),
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: BrokaColors.bgCard.withOpacity(0.75),
            border: Border.all(color: BrokaColors.neonCyan.withOpacity(0.35)),
            boxShadow: [BoxShadow(color: BrokaColors.neonPurple.withOpacity(0.18), blurRadius: 12)],
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 14, color: BrokaColors.neonCyan),
            const SizedBox(width: 6),
            Text(label,
                style: const TextStyle(color: BrokaColors.textHigh, fontSize: 12, fontWeight: FontWeight.w700)),
          ]),
        ),
      );
}

// ── The card ─────────────────────────────────────────────────────────────────

class _TourCard extends StatefulWidget {
  const _TourCard({super.key, required this.session});

  final ZenoSession session;

  @override
  State<_TourCard> createState() => _TourCardState();
}

class _TourCardState extends State<_TourCard> with SingleTickerProviderStateMixin {
  final _field = TextEditingController();

  /// The current segment filling up while the tour waits to move on.
  late final AnimationController _wait;

  ZenoTour get _tour => widget.session.tour;

  @override
  void initState() {
    super.initState();
    _wait = AnimationController(vsync: this, duration: ZenoTour.linger);
    _tour.addListener(_syncWait);
  }

  @override
  void dispose() {
    _tour.removeListener(_syncWait);
    _wait.dispose();
    _field.dispose();
    super.dispose();
  }

  void _syncWait() {
    if (!mounted) return;
    if (_tour.waiting) {
      if (!_wait.isAnimating && _wait.value == 0) {
        BrokaMotion.reduced(context) ? _wait.value = 1 : _wait.forward(from: 0);
      }
    } else if (_wait.value != 0) {
      _wait.value = 0;
    }
  }

  void _submit([String? text]) {
    final q = (text ?? _field.text).trim();
    if (q.isEmpty) return;
    FocusScope.of(context).unfocus();
    _field.clear();
    _tour.submitDemo(q);
  }

  @override
  Widget build(BuildContext context) {
    final tour = _tour;
    final phase = tour.phase;
    final step = tour.step;
    final (overline, title) = switch (phase) {
      ZenoTourPhase.step => ('ZENO TOUR · ${tour.index + 1} OF ${tour.stepCount}', step?.title ?? ''),
      ZenoTourPhase.demo => ('ZENO TOUR · YOUR TURN', tour.demoQuery == null ? 'Try me' : 'On it'),
      _ => ('ZENO TOUR · DONE', tour.demoRan ? "That's me at work" : "You're all set"),
    };
    return Material(
      type: MaterialType.transparency,
      child: _HoloFrame(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              ZenoOrb(
                mode: tour.speaking ? ZenoOrbMode.speaking : ZenoOrbMode.listening,
                level: tour.speaking ? 0.3 : 0.05,
                size: 42,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text(overline,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: BrokaColors.neonCyan, fontSize: 9.5, fontWeight: FontWeight.w800, letterSpacing: 1.5)),
                  const SizedBox(height: 2),
                  AgentShimmerText(title,
                      key: ValueKey(title),
                      maxLines: 1,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
                ]),
              ),
              IconButton(
                tooltip: 'End the tour',
                visualDensity: VisualDensity.compact,
                onPressed: tour.end,
                icon: const Icon(Icons.close_rounded, color: BrokaColors.textMid, size: 20),
              ),
            ]),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.22),
                child: SingleChildScrollView(
                  child: ZenoStreamingText(
                    tour.line,
                    key: ValueKey('${tour.phase}:${tour.index}:${tour.line}'),
                    style: const TextStyle(color: BrokaColors.textHigh, fontSize: 14, height: 1.45),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            if (phase == ZenoTourPhase.step) ...[
              _Progress(count: tour.stepCount, at: tour.index, wait: _wait),
              const SizedBox(height: 8),
              Row(children: [
                TextButton.icon(
                  onPressed: tour.index == 0 ? null : tour.back,
                  icon: const Icon(Icons.arrow_back_rounded, size: 16),
                  label: const Text('Back'),
                  style: TextButton.styleFrom(foregroundColor: BrokaColors.textMid),
                ),
                const Spacer(),
                _GlowButton(
                  key: const Key('zeno-tour-next'),
                  label: tour.index == tour.stepCount - 1 ? 'Try it' : 'Next',
                  icon: Icons.arrow_forward_rounded,
                  compact: true,
                  onTap: tour.next,
                ),
                const SizedBox(width: 6),
              ]),
            ] else if (phase == ZenoTourPhase.demo && tour.demoQuery == null) ...[
              _demoInput(),
              const SizedBox(height: 8),
              SizedBox(
                height: 34,
                child: ListView(scrollDirection: Axis.horizontal, children: [
                  for (final (emoji, idea) in ZenoTourScript.demoIdeas)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: ActionChip(
                        label: Text('$emoji $idea'),
                        labelStyle: const TextStyle(color: BrokaColors.textHigh, fontSize: 12),
                        backgroundColor: BrokaColors.bgCard,
                        side: BorderSide(color: BrokaColors.neonPurple.withOpacity(0.45)),
                        shape: const StadiumBorder(),
                        onPressed: () => _submit(idea),
                      ),
                    ),
                ]),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: tour.skipDemo,
                  child: const Text('Skip', style: TextStyle(color: BrokaColors.textMid)),
                ),
              ),
            ] else if (phase == ZenoTourPhase.finale)
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: _GlowButton(
                    key: const Key('zeno-tour-done'),
                    label: tour.demoRan ? 'Got it' : 'Start exploring',
                    icon: Icons.check_rounded,
                    compact: true,
                    onTap: tour.end,
                  ),
                ),
              ),
          ]),
        ),
      ),
    );
  }

  Widget _demoInput() => Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.only(left: 12),
        decoration: BoxDecoration(
          color: BrokaColors.bg.withOpacity(0.6),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.55)),
        ),
        child: Row(children: [
          Expanded(
            child: TextField(
              key: const Key('zeno-tour-demo-field'),
              controller: _field,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _submit(),
              style: const TextStyle(color: BrokaColors.textHigh, fontSize: 14),
              cursorColor: BrokaColors.neonCyan,
              decoration: const InputDecoration(
                hintText: 'e.g. a phone under 20K',
                hintStyle: TextStyle(color: BrokaColors.textMid),
                filled: false,
                isDense: true,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Say it',
            onPressed: _tour.listen,
            icon: const Icon(Icons.mic_rounded, color: BrokaColors.neonCyan, size: 20),
          ),
          IconButton(
            tooltip: 'Find it',
            onPressed: _submit,
            icon: const Icon(Icons.travel_explore_rounded, color: BrokaColors.textHigh, size: 20),
          ),
        ]),
      );
}

/// The tour's steps as segments; the current one fills while the tour
/// waits to move on.
class _Progress extends StatelessWidget {
  const _Progress({required this.count, required this.at, required this.wait});

  final int count;
  final int at;
  final Animation<double> wait;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 6),
        child: AnimatedBuilder(
          animation: wait,
          builder: (_, __) => Row(children: [
            for (var i = 0; i < count; i++)
              Expanded(
                child: Container(
                  height: 4,
                  margin: EdgeInsets.only(right: i == count - 1 ? 0 : 4),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(2),
                    color: BrokaColors.border,
                  ),
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: i < at ? 1 : (i == at ? 0.35 + 0.65 * wait.value : 0),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(2),
                        gradient: const LinearGradient(colors: [BrokaColors.neonPurple, BrokaColors.neonCyan]),
                      ),
                    ),
                  ),
                ),
              ),
          ]),
        ),
      );
}

/// Glass with a gradient hairline and a violet glow - the tour card's frame.
class _HoloFrame extends StatelessWidget {
  const _HoloFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [BrokaColors.neonPurple, BrokaColors.neonBlue, BrokaColors.neonCyan],
          ),
          boxShadow: [
            BoxShadow(color: BrokaColors.neonPurple.withOpacity(0.35), blurRadius: 26, spreadRadius: -2),
            BoxShadow(color: Colors.black.withOpacity(0.55), blurRadius: 18, offset: const Offset(0, 8)),
          ],
        ),
        child: Container(
          margin: const EdgeInsets.all(1.2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(21),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xF5141B3A), Color(0xF50A0F1F)],
            ),
          ),
          child: child,
        ),
      );
}

/// The tour's buttons: Zeno's gradient, a glow, and a press that gives.
class _GlowButton extends StatelessWidget {
  const _GlowButton({super.key, required this.label, required this.icon, required this.onTap, this.compact = false});

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool compact;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: label,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(30),
            child: Ink(
              padding: EdgeInsets.symmetric(horizontal: compact ? 18 : 30, vertical: compact ? 10 : 15),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(30),
                gradient: const LinearGradient(colors: [BrokaColors.neonPurple, BrokaColors.neonBlue]),
                boxShadow: [BoxShadow(color: BrokaColors.neonBlue.withOpacity(0.45), blurRadius: 18)],
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(label,
                    style: TextStyle(
                        color: Colors.white, fontSize: compact ? 13.5 : 15.5, fontWeight: FontWeight.w800)),
                const SizedBox(width: 8),
                Icon(icon, size: compact ? 16 : 18, color: Colors.white),
              ]),
            ),
          ),
        ),
      );
}
