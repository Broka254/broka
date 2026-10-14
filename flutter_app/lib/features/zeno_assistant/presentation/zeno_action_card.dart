// What Zeno is doing, or asking to do, under its reply - in the typed
// conversation and, larger, in voice mode.
//
//   an action that runs by itself   a chip with a light running through it,
//                                   then "open again" once it has happened
//   a person to pick                one button per person it could be
//   a call                          who, about what, and [Not now] [Call] -
//                                   nothing rings until Call is tapped
//   a search Zeno offers            what it would look for, and [Not now]
//                                   [Find it] - asked about a listing that
//                                   doesn't fit, it waits for the buyer
//   a guide                         its steps, each with the way to where it
//                                   is done (zeno_guide_card.dart)
import 'package:flutter/material.dart';

import '../../../main.dart' show BrokaColors;
import '../../../theme/motion.dart';
import '../domain/zeno_action.dart';
import '../zeno_action_runner.dart';
import 'zeno_guide_card.dart';

enum ZenoActionPhase { pending, running, done, dismissed }

class ZenoActionCard extends StatelessWidget {
  const ZenoActionCard({
    super.key,
    required this.action,
    required this.phase,
    this.large = false,
    this.onConfirm,
    this.onDismiss,
    this.onChoose,
    this.onStep,
    this.visited = const {},
    this.folded = false,
    this.onFold,
  });

  final ZenoAction action;
  final ZenoActionPhase phase;

  /// Voice mode's size.
  final bool large;

  /// A call: place it. An offered search: run it. Anything else: do it
  /// again.
  final VoidCallback? onConfirm;
  final VoidCallback? onDismiss;
  final ValueChanged<ZenoContact>? onChoose;

  /// A guide: one of its steps' "Take me there", and how far along it is.
  final ValueChanged<int>? onStep;
  final Set<int> visited;
  final bool folded;
  final ValueChanged<bool>? onFold;

  @override
  Widget build(BuildContext context) {
    final Widget body;
    if (action.type == ZenoActionType.guide && action.guide != null) {
      body = ZenoGuideCard(
        guide: action.guide!,
        large: large,
        visited: visited,
        folded: folded,
        onFold: onFold,
        onDismiss: onDismiss,
        onOpen: onStep ?? (_) {},
      );
    } else if (action.choices.isNotEmpty) {
      body = _Choices(action: action, large: large, onChoose: onChoose, onDismiss: onDismiss, phase: phase);
    } else if (action.type == ZenoActionType.call) {
      body = _CallConfirm(action: action, phase: phase, large: large, onConfirm: onConfirm, onDismiss: onDismiss);
    } else if (action.isOffer && phase != ZenoActionPhase.done) {
      body = _Offer(action: action, phase: phase, large: large, onConfirm: onConfirm, onDismiss: onDismiss);
    } else {
      body = _Chip(action: action, phase: phase, large: large, onAgain: onConfirm);
    }
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: BrokaMotion.of(context, const Duration(milliseconds: 520)),
      curve: Curves.easeOutBack,
      builder: (_, v, child) => Opacity(
        opacity: v.clamp(0.0, 1.0),
        child: Transform.scale(scale: 0.85 + 0.15 * v, alignment: Alignment.topLeft, child: child),
      ),
      child: body,
    );
  }
}

BoxDecoration _glass(Color edge, {bool large = false}) => BoxDecoration(
      borderRadius: BorderRadius.circular(large ? 22 : 16),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        // Opaque: in Zeno's session the card sits over any screen, and a
        // screen's text showing through a call confirmation is unreadable.
        colors: [Color.alphaBlend(edge.withOpacity(0.18), BrokaColors.bgCard), BrokaColors.bgCard],
      ),
      border: Border.all(color: edge.withOpacity(0.55)),
      boxShadow: [BoxShadow(color: edge.withOpacity(0.22), blurRadius: large ? 26 : 14)],
    );

class _Chip extends StatefulWidget {
  const _Chip({required this.action, required this.phase, required this.large, this.onAgain});

  final ZenoAction action;
  final ZenoActionPhase phase;
  final bool large;
  final VoidCallback? onAgain;

  @override
  State<_Chip> createState() => _ChipState();
}

class _ChipState extends State<_Chip> with SingleTickerProviderStateMixin {
  late final AnimationController _run =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_Chip old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final running = widget.phase != ZenoActionPhase.done && !BrokaMotion.reduced(context);
    if (running && !_run.isAnimating) {
      _run.repeat();
    } else if (!running && _run.isAnimating) {
      _run.stop();
    }
  }

  @override
  void dispose() {
    _run.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final done = widget.phase == ZenoActionPhase.done;
    final large = widget.large;
    const tone = BrokaColors.neonCyan;
    return GestureDetector(
      onTap: done ? widget.onAgain : null,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: large ? 16 : 12, vertical: large ? 12 : 9),
        decoration: _glass(tone, large: large),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: large ? 34 : 26,
            height: large ? 34 : 26,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(colors: [BrokaColors.neonPurple, BrokaColors.neonBlue]),
            ),
            child: Icon(ZenoActionRunner.icon(widget.action), size: large ? 18 : 14, color: Colors.white),
          ),
          SizedBox(width: large ? 12 : 9),
          Flexible(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(ZenoActionRunner.label(widget.action),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: BrokaColors.textHigh,
                      fontSize: large ? 15 : 12.5,
                      fontWeight: FontWeight.w800)),
              const SizedBox(height: 5),
              SizedBox(
                width: large ? 170 : 130,
                height: 3,
                child: done
                    ? DecoratedBox(
                        decoration: BoxDecoration(
                            color: BrokaColors.success, borderRadius: BorderRadius.circular(2)))
                    : AnimatedBuilder(
                        animation: _run,
                        builder: (_, __) => CustomPaint(painter: _SweepPainter(_run.value)),
                      ),
              ),
            ]),
          ),
          if (done && widget.onAgain != null) ...[
            SizedBox(width: large ? 12 : 9),
            Icon(Icons.replay_rounded, size: large ? 18 : 15, color: BrokaColors.textMid),
          ],
        ]),
      ),
    );
  }
}

class _SweepPainter extends CustomPainter {
  _SweepPainter(this.t);
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final rr = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(2));
    canvas.drawRRect(rr, Paint()..color = BrokaColors.border);
    final w = size.width * 0.4;
    final x = -w + (size.width + w) * Curves.easeInOut.transform(t);
    canvas.save();
    canvas.clipRRect(rr);
    canvas.drawRect(
      Rect.fromLTWH(x, 0, w, size.height),
      Paint()
        ..shader = LinearGradient(colors: [
          BrokaColors.neonCyan.withOpacity(0),
          BrokaColors.neonCyan,
          BrokaColors.neonCyan.withOpacity(0),
        ]).createShader(Rect.fromLTWH(x, 0, w, size.height)),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_SweepPainter old) => old.t != t;
}

class _CallConfirm extends StatelessWidget {
  const _CallConfirm({
    required this.action,
    required this.phase,
    required this.large,
    this.onConfirm,
    this.onDismiss,
  });

  final ZenoAction action;
  final ZenoActionPhase phase;
  final bool large;
  final VoidCallback? onConfirm;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final c = action.target!;
    final video = action.video;
    final dismissed = phase == ZenoActionPhase.dismissed;
    final tone = dismissed ? BrokaColors.textMid : BrokaColors.success;
    return AnimatedOpacity(
      duration: BrokaMotion.quick,
      opacity: dismissed ? 0.55 : 1,
      child: Container(
        padding: EdgeInsets.all(large ? 16 : 12),
        decoration: _glass(tone, large: large),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            _PeerBadge(name: c.peerName, video: video, large: large, live: phase == ZenoActionPhase.pending),
            SizedBox(width: large ? 14 : 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  switch (phase) {
                    ZenoActionPhase.running => 'Calling ${c.firstName}…',
                    ZenoActionPhase.done => 'Call started',
                    ZenoActionPhase.dismissed => 'Call cancelled',
                    ZenoActionPhase.pending => '${video ? 'Video call' : 'Call'} ${c.peerName}?',
                  },
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: BrokaColors.textHigh, fontSize: large ? 17 : 13.5, fontWeight: FontWeight.w800),
                ),
                if (c.listingName.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text('About ${c.listingName}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: BrokaColors.textMid, fontSize: large ? 13 : 11.5)),
                ],
              ]),
            ),
          ]),
          if (phase == ZenoActionPhase.pending) ...[
            SizedBox(height: large ? 16 : 12),
            Row(children: [
              Expanded(
                child: _Button(
                  label: 'Not now',
                  onTap: onDismiss,
                  large: large,
                  filled: false,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _Button(
                  label: video ? 'Video call' : 'Call',
                  icon: video ? Icons.videocam_rounded : Icons.call_rounded,
                  onTap: onConfirm,
                  large: large,
                  filled: true,
                ),
              ),
            ]),
          ],
          if (phase == ZenoActionPhase.running)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: LinearProgressIndicator(
                minHeight: 2,
                color: BrokaColors.success,
                backgroundColor: BrokaColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
        ]),
      ),
    );
  }
}

/// A search Zeno offers instead of running: asked about a listing that
/// doesn't fit, Zeno says what it would look for, and the buyer decides.
/// Once taken it becomes the ordinary chip - "open again" - like any
/// search that ran by itself.
class _Offer extends StatelessWidget {
  const _Offer({
    required this.action,
    required this.phase,
    required this.large,
    this.onConfirm,
    this.onDismiss,
  });

  final ZenoAction action;
  final ZenoActionPhase phase;
  final bool large;
  final VoidCallback? onConfirm;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final dismissed = phase == ZenoActionPhase.dismissed;
    final agent = action.type == ZenoActionType.findForMe;
    final tone = dismissed ? BrokaColors.textMid : BrokaColors.neonCyan;
    return AnimatedOpacity(
      duration: BrokaMotion.quick,
      opacity: dismissed ? 0.55 : 1,
      child: Container(
        padding: EdgeInsets.all(large ? 16 : 12),
        decoration: _glass(tone, large: large),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Container(
              width: large ? 34 : 28,
              height: large ? 34 : 28,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(colors: [BrokaColors.neonPurple, BrokaColors.neonBlue]),
              ),
              child: Icon(ZenoActionRunner.icon(action), size: large ? 18 : 15, color: Colors.white),
            ),
            SizedBox(width: large ? 12 : 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  dismissed
                      ? 'Not searching'
                      : (agent ? 'Find something that fits?' : 'Search for something else?'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: BrokaColors.textHigh, fontSize: large ? 16 : 13.5, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 2),
                Text('"${action.query}"',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: BrokaColors.textMid, fontSize: large ? 13 : 11.5)),
              ]),
            ),
          ]),
          if (phase == ZenoActionPhase.pending) ...[
            SizedBox(height: large ? 16 : 12),
            Row(children: [
              Expanded(child: _Button(label: 'Not now', onTap: onDismiss, large: large, filled: false)),
              const SizedBox(width: 10),
              Expanded(
                child: _Button(
                  label: agent ? 'Find it' : 'Search',
                  icon: agent ? Icons.radar_rounded : Icons.search_rounded,
                  onTap: onConfirm,
                  large: large,
                  filled: true,
                ),
              ),
            ]),
          ],
          if (phase == ZenoActionPhase.running)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: LinearProgressIndicator(
                minHeight: 2,
                color: BrokaColors.neonCyan,
                backgroundColor: BrokaColors.border,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
        ]),
      ),
    );
  }
}

/// The person's initial in a ring that pings while the call waits for a
/// yes - the same "about to ring" signal as the VoIP screen's avatar.
class _PeerBadge extends StatefulWidget {
  const _PeerBadge({required this.name, required this.video, required this.large, required this.live});

  final String name;
  final bool video;
  final bool large;
  final bool live;

  @override
  State<_PeerBadge> createState() => _PeerBadgeState();
}

class _PeerBadgeState extends State<_PeerBadge> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(_PeerBadge old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final on = widget.live && !BrokaMotion.reduced(context);
    if (on && !_c.isAnimating) {
      _c.repeat();
    } else if (!on && _c.isAnimating) {
      _c.stop();
      _c.value = 0;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.large ? 52.0 : 40.0;
    final initial = widget.name.trim().isEmpty ? '?' : widget.name.trim()[0].toUpperCase();
    return SizedBox.square(
      dimension: d,
      child: CustomPaint(
        painter: _PingPainter(_c),
        child: Stack(clipBehavior: Clip.none, children: [
          Container(
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(colors: [BrokaColors.neonPurple, BrokaColors.neonBlue]),
            ),
            alignment: Alignment.center,
            child: Text(initial,
                style: TextStyle(color: Colors.white, fontSize: d * 0.42, fontWeight: FontWeight.w900)),
          ),
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              padding: const EdgeInsets.all(3),
              decoration: const BoxDecoration(shape: BoxShape.circle, color: BrokaColors.success),
              child: Icon(widget.video ? Icons.videocam_rounded : Icons.call_rounded,
                  size: d * 0.26, color: Colors.white),
            ),
          ),
        ]),
      ),
    );
  }
}

class _PingPainter extends CustomPainter {
  _PingPainter(this.a) : super(repaint: a);
  final Animation<double> a;

  @override
  void paint(Canvas canvas, Size size) {
    if (a.value == 0) return;
    final c = size.center(Offset.zero);
    for (var i = 0; i < 2; i++) {
      final p = (a.value + i / 2) % 1.0;
      canvas.drawCircle(
        c,
        size.width / 2 * (1 + 0.6 * p),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = BrokaColors.success.withOpacity(0.6 * (1 - p)),
      );
    }
  }

  @override
  bool shouldRepaint(_PingPainter old) => old.a != a;
}

class _Choices extends StatelessWidget {
  const _Choices({
    required this.action,
    required this.large,
    required this.phase,
    this.onChoose,
    this.onDismiss,
  });

  final ZenoAction action;
  final bool large;
  final ZenoActionPhase phase;
  final ValueChanged<ZenoContact>? onChoose;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final call = action.type == ZenoActionType.call;
    return Container(
      padding: EdgeInsets.all(large ? 14 : 10),
      decoration: _glass(BrokaColors.neonPurple, large: large),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Text(call ? 'Who should I call?' : 'Whose chat?',
            style: TextStyle(color: BrokaColors.textMid, fontSize: large ? 13 : 11.5, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        for (final (i, c) in action.choices.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: BrokaMotion.of(context, Duration(milliseconds: 380 + 90 * i)),
              curve: Curves.easeOutCubic,
              builder: (_, v, child) => Opacity(
                opacity: v,
                child: Transform.translate(offset: Offset(24 * (1 - v), 0), child: child),
              ),
              child: Material(
                color: BrokaColors.bgCard.withOpacity(0.9),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: BrokaColors.neonPurple.withOpacity(0.4)),
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: phase == ZenoActionPhase.pending && onChoose != null ? () => onChoose!(c) : null,
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: large ? 12 : 9),
                    child: Row(children: [
                      CircleAvatar(
                        radius: large ? 15 : 12,
                        backgroundColor: BrokaColors.neonPurple.withOpacity(0.35),
                        child: Text(c.peerName.isEmpty ? '?' : c.peerName[0].toUpperCase(),
                            style: TextStyle(
                                color: Colors.white, fontSize: large ? 13 : 11, fontWeight: FontWeight.w800)),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(c.peerName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: BrokaColors.textHigh,
                                  fontSize: large ? 15 : 13,
                                  fontWeight: FontWeight.w700)),
                          if (c.listingName.isNotEmpty)
                            Text(c.listingName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(color: BrokaColors.textMid, fontSize: large ? 12 : 11)),
                        ]),
                      ),
                      Icon(call ? (action.video ? Icons.videocam_rounded : Icons.call_rounded) : Icons.chevron_right_rounded,
                          size: large ? 20 : 17, color: call ? BrokaColors.success : BrokaColors.textMid),
                    ]),
                  ),
                ),
              ),
            ),
          ),
        if (onDismiss != null && phase == ZenoActionPhase.pending)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: onDismiss,
              child: const Text('Never mind', style: TextStyle(color: BrokaColors.textMid)),
            ),
          ),
      ]),
    );
  }
}

class _Button extends StatelessWidget {
  const _Button({required this.label, required this.onTap, required this.large, required this.filled, this.icon});

  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool large;
  final bool filled;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            height: large ? 50 : 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(large ? 16 : 12),
              gradient: filled
                  ? const LinearGradient(colors: [Color(0xFF059669), BrokaColors.success])
                  : null,
              color: filled ? null : BrokaColors.bgCard.withOpacity(0.9),
              border: filled ? null : Border.all(color: BrokaColors.border),
              boxShadow: filled
                  ? [BoxShadow(color: BrokaColors.success.withOpacity(0.35), blurRadius: 14, offset: const Offset(0, 3))]
                  : null,
            ),
            // Half a narrow card, at a large text size, is less room than
            // "Video call" wants: the label shrinks rather than overflow.
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                if (icon != null) ...[
                  Icon(icon, size: large ? 20 : 16, color: Colors.white),
                  const SizedBox(width: 6),
                ],
                Text(label,
                    style: TextStyle(
                        color: filled ? Colors.white : BrokaColors.textMid,
                        fontSize: large ? 15 : 13,
                        fontWeight: FontWeight.w800)),
              ]),
            ),
          ),
        ),
      );
}
