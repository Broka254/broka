// A guide from Zeno - "how do I open a store?", "tips to sell faster" - as
// steps to follow rather than a paragraph to remember.
//
// Each step has a button to the screen where it is done. Following one
// doesn't lose the guide: in Zeno's session the card folds into a bar above
// the pill, with the steps already taken ticked, and opens again for the
// next one - the guide goes with the user through the app, the way the
// rest of the session does (zeno_session.dart).
//
// The steps are the server's (zeno_assistant/guides.py), built from the
// user's own account: every figure in them - "40% above the median of 6
// similar listings" - was computed, not written by a model.
import 'package:flutter/material.dart';

import '../../../main.dart' show BrokaColors;
import '../../../theme/motion.dart';
import '../domain/zeno_action.dart';
import '../zeno_action_runner.dart';

class ZenoGuideCard extends StatefulWidget {
  const ZenoGuideCard({
    super.key,
    required this.guide,
    required this.onOpen,
    this.visited = const {},
    this.large = false,
    this.folded = false,
    this.onFold,
    this.onDismiss,
  });

  final ZenoGuide guide;

  /// A step's "Take me there".
  final ValueChanged<int> onOpen;

  /// Steps already followed, when someone else keeps count (the session).
  final Set<int> visited;
  final bool large;

  /// Down to one bar with the progress, when [onFold] is given.
  final bool folded;
  final ValueChanged<bool>? onFold;
  final VoidCallback? onDismiss;

  @override
  State<ZenoGuideCard> createState() => _ZenoGuideCardState();
}

class _ZenoGuideCardState extends State<ZenoGuideCard> with SingleTickerProviderStateMixin {
  late final AnimationController _in = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: 420 + 110 * widget.guide.steps.length.clamp(1, 8)),
  );

  // The chat's copy of the card counts for itself.
  final Set<int> _visited = {};

  Set<int> get _done => {...widget.visited, ..._visited};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (BrokaMotion.reduced(context)) {
      _in.value = 1;
    } else if (_in.value == 0 && !_in.isAnimating) {
      _in.forward();
    }
  }

  @override
  void dispose() {
    _in.dispose();
    super.dispose();
  }

  void _open(int i) {
    setState(() => _visited.add(i));
    widget.onOpen(i);
  }

  @override
  Widget build(BuildContext context) {
    final guide = widget.guide;
    final done = _done.length.clamp(0, guide.steps.length);
    final large = widget.large;
    return AnimatedSize(
      duration: BrokaMotion.of(context, BrokaMotion.standard),
      curve: BrokaMotion.enter,
      alignment: Alignment.bottomCenter,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(large ? 22 : 18),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            // Opaque: docked, the card sits over whatever screen is open.
            colors: [Color.alphaBlend(BrokaColors.neonPurple.withOpacity(0.2), BrokaColors.bgCard), BrokaColors.bgCard],
          ),
          border: Border.all(color: BrokaColors.neonPurple.withOpacity(0.5)),
          boxShadow: [BoxShadow(color: BrokaColors.neonPurple.withOpacity(0.25), blurRadius: large ? 26 : 16)],
        ),
        child: widget.folded && widget.onFold != null
            ? _FoldedBar(guide: guide, done: done, onTap: () => widget.onFold!(false), onDismiss: widget.onDismiss)
            : Padding(
                padding: EdgeInsets.fromLTRB(large ? 16 : 14, large ? 14 : 12, large ? 10 : 8, large ? 12 : 10),
                // In the chat's list the card is as tall as its steps; over
                // a screen it is given a height, and scrolls within it.
                child: LayoutBuilder(builder: (context, box) {
                  final steps = Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      for (final (i, step) in guide.steps.indexed)
                        _StepRow(
                          key: ValueKey('guide-step-$i'),
                          index: i,
                          step: step,
                          last: i == guide.steps.length - 1,
                          done: _done.contains(i),
                          large: large,
                          // drive(), not a CurvedAnimation: this runs on every
                          // rebuild, and each CurvedAnimation would leave a
                          // listener on the controller that nothing removes.
                          appear: _in.drive(CurveTween(
                            curve: Interval(
                              (0.12 * i).clamp(0.0, 0.7),
                              (0.12 * i + 0.45).clamp(0.3, 1.0),
                              curve: Curves.easeOutCubic,
                            ),
                          )),
                          onOpen: step.destination == null ? null : () => _open(i),
                        ),
                    ]),
                  );
                  return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                    _Header(
                      guide: guide,
                      done: done,
                      large: large,
                      onFold: widget.onFold == null ? null : () => widget.onFold!(true),
                      onDismiss: widget.onDismiss,
                    ),
                    if (guide.intro.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Text(guide.intro,
                            style: TextStyle(color: BrokaColors.textMid, fontSize: large ? 13.5 : 12.5, height: 1.35)),
                      ),
                    ],
                    const SizedBox(height: 10),
                    if (box.maxHeight.isFinite) Flexible(child: SingleChildScrollView(child: steps)) else steps,
                  ]);
                }),
              ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.guide, required this.done, required this.large, this.onFold, this.onDismiss});

  final ZenoGuide guide;
  final int done;
  final bool large;
  final VoidCallback? onFold;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) => Row(children: [
        const _Spark(),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(guide.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: BrokaColors.textHigh, fontSize: large ? 17 : 14.5, fontWeight: FontWeight.w800)),
            const SizedBox(height: 4),
            _Progress(done: done, total: guide.steps.length),
          ]),
        ),
        if (onFold != null)
          IconButton(
            tooltip: 'Fold the guide',
            visualDensity: VisualDensity.compact,
            onPressed: onFold,
            icon: const Icon(Icons.expand_more_rounded, color: BrokaColors.textMid),
          ),
        if (onDismiss != null)
          IconButton(
            tooltip: 'Close the guide',
            visualDensity: VisualDensity.compact,
            onPressed: onDismiss,
            icon: const Icon(Icons.close_rounded, color: BrokaColors.textMid, size: 20),
          ),
      ]);
}

/// "2 of 4 done", and a bar that fills as they are.
class _Progress extends StatelessWidget {
  const _Progress({required this.done, required this.total});

  final int done;
  final int total;

  @override
  Widget build(BuildContext context) => Row(children: [
        SizedBox(
          width: 64,
          height: 4,
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: total == 0 ? 0 : done / total),
            duration: BrokaMotion.of(context, const Duration(milliseconds: 600)),
            curve: Curves.easeOutCubic,
            builder: (_, v, __) => ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: Stack(children: [
                const Positioned.fill(child: ColoredBox(color: BrokaColors.border)),
                FractionallySizedBox(
                  widthFactor: v.clamp(0.0, 1.0),
                  child: const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(colors: [BrokaColors.neonPurple, BrokaColors.neonCyan]),
                    ),
                    child: SizedBox.expand(),
                  ),
                ),
              ]),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(done == 0 ? '$total steps' : '$done of $total done',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5, fontWeight: FontWeight.w600)),
        ),
      ]);
}

class _Spark extends StatelessWidget {
  const _Spark();

  @override
  Widget build(BuildContext context) => Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(colors: [BrokaColors.neonPurple, BrokaColors.neonBlue]),
          boxShadow: [BoxShadow(color: BrokaColors.neonPurple.withOpacity(0.5), blurRadius: 12)],
        ),
        child: const Icon(Icons.auto_awesome_rounded, size: 16, color: Colors.white),
      );
}

/// One step: its number on a rail that joins it to the next, what to do,
/// and the button to where it is done.
class _StepRow extends StatelessWidget {
  const _StepRow({
    super.key,
    required this.index,
    required this.step,
    required this.last,
    required this.done,
    required this.large,
    required this.appear,
    this.onOpen,
  });

  final int index;
  final ZenoGuideStep step;
  final bool last;
  final bool done;
  final bool large;
  final Animation<double> appear;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final dot = large ? 28.0 : 24.0;
    return AnimatedBuilder(
      animation: appear,
      builder: (_, child) => Opacity(
        opacity: appear.value.clamp(0.0, 1.0),
        child: Transform.translate(offset: Offset(0, 14 * (1 - appear.value)), child: child),
      ),
      child: IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(
            width: dot,
            child: Column(children: [
              AnimatedContainer(
                duration: BrokaMotion.of(context, BrokaMotion.standard),
                width: dot,
                height: dot,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: done
                      ? const LinearGradient(colors: [Color(0xFF059669), BrokaColors.success])
                      : const LinearGradient(colors: [BrokaColors.neonPurple, BrokaColors.neonBlue]),
                  boxShadow: [
                    BoxShadow(
                        color: (done ? BrokaColors.success : BrokaColors.neonBlue).withOpacity(0.4), blurRadius: 10),
                  ],
                ),
                alignment: Alignment.center,
                child: AnimatedSwitcher(
                  duration: BrokaMotion.of(context, BrokaMotion.quick),
                  transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
                  child: done
                      ? Icon(Icons.check_rounded, key: const ValueKey('done'), size: dot * 0.6, color: Colors.white)
                      : Text('${index + 1}',
                          key: const ValueKey('n'),
                          style: TextStyle(
                              color: Colors.white, fontSize: large ? 13 : 12, fontWeight: FontWeight.w800)),
                ),
              ),
              if (!last)
                Expanded(
                  child: Container(
                    width: 2,
                    margin: const EdgeInsets.symmetric(vertical: 3),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(1),
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          (done ? BrokaColors.success : BrokaColors.neonBlue).withOpacity(0.7),
                          BrokaColors.border,
                        ],
                      ),
                    ),
                  ),
                ),
            ]),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: last ? 2 : 14, top: 2),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(step.title,
                    style: TextStyle(
                      color: done ? BrokaColors.textMid : BrokaColors.textHigh,
                      fontSize: large ? 15 : 13.5,
                      fontWeight: FontWeight.w700,
                    )),
                if (step.detail.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(step.detail,
                      style: TextStyle(color: BrokaColors.textMid, fontSize: large ? 13 : 12, height: 1.35)),
                ],
                if (onOpen != null) ...[
                  const SizedBox(height: 8),
                  _GoButton(destination: step.destination!, done: done, onTap: onOpen!),
                ],
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}

class _GoButton extends StatelessWidget {
  const _GoButton({required this.destination, required this.done, required this.onTap});

  final String destination;
  final bool done;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: onTap,
            child: Ink(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                gradient: done
                    ? null
                    : const LinearGradient(colors: [BrokaColors.neonPurple, BrokaColors.neonBlue]),
                color: done ? BrokaColors.bgCard : null,
                border: done ? Border.all(color: BrokaColors.border) : null,
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(ZenoActionRunner.destinationIcon(destination), size: 15, color: Colors.white),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(done ? 'Open again' : 'Take me there',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w700)),
                ),
              ]),
            ),
          ),
        ),
      );
}

/// The guide folded above the pill: what it is, how far along, and the
/// next step.
class _FoldedBar extends StatelessWidget {
  const _FoldedBar({required this.guide, required this.done, required this.onTap, this.onDismiss});

  final ZenoGuide guide;
  final int done;
  final VoidCallback onTap;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final next = done < guide.steps.length ? guide.steps[done].title : 'All done';
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Row(children: [
            SizedBox.square(
              dimension: 30,
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: guide.steps.isEmpty ? 0 : done / guide.steps.length),
                duration: BrokaMotion.of(context, const Duration(milliseconds: 600)),
                builder: (_, v, __) => CircularProgressIndicator(
                  value: v,
                  strokeWidth: 3,
                  color: BrokaColors.success,
                  backgroundColor: BrokaColors.border,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(guide.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: BrokaColors.textHigh, fontSize: 13, fontWeight: FontWeight.w800)),
                Text(done < guide.steps.length ? 'Next: $next' : next,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5)),
              ]),
            ),
            const Icon(Icons.expand_less_rounded, color: BrokaColors.textMid),
            if (onDismiss != null)
              IconButton(
                tooltip: 'Close the guide',
                visualDensity: VisualDensity.compact,
                onPressed: onDismiss,
                icon: const Icon(Icons.close_rounded, color: BrokaColors.textMid, size: 18),
              ),
          ]),
        ),
      ),
    );
  }
}
