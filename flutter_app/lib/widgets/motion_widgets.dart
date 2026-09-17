// BROKA — motion primitives
//
// Three widgets that cover most of what the app was hand-rolling an
// AnimationController for. All of them honour the OS reduce-motion setting
// and none of them need a State subclass at the call site.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../main.dart' show BrokaColors;
import '../theme/motion.dart';

/// Fades and lifts a widget into place once, on first build.
///
/// Pass [index] inside a list or grid and consecutive items arrive in
/// sequence rather than all at once. Stateless and self-contained — no
/// controller to create, remember to dispose, or leak.
///
/// Uses TweenAnimationBuilder rather than an AnimationController on
/// purpose: a one-shot entrance has no reason to hold a ticker for the life
/// of the screen, and 76 controllers is already more than this app should
/// be carrying.
class FadeSlideIn extends StatelessWidget {
  final Widget child;
  final int index;
  final Duration duration;

  /// Travel distance in logical pixels. Positive rises from below.
  final double offsetY;

  const FadeSlideIn({
    super.key,
    required this.child,
    this.index = 0,
    this.duration = BrokaMotion.quick,
    this.offsetY = 14,
  });

  @override
  Widget build(BuildContext context) {
    if (BrokaMotion.reduced(context)) return child;

    final delay = BrokaMotion.stagger *
        math.min(index, BrokaMotion.maxStaggerIndex);

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: duration + delay,
      curve: Interval(
        // Express the delay as a dead zone at the head of one tween rather
        // than as a Future.delayed. A delayed build would pop the widget in
        // at full opacity for one frame before the animation took over.
        delay.inMilliseconds / (duration + delay).inMilliseconds,
        1.0,
        curve: BrokaMotion.enter,
      ),
      builder: (_, t, c) => Opacity(
        opacity: t.clamp(0.0, 1.0),
        child: Transform.translate(offset: Offset(0, (1 - t) * offsetY), child: c),
      ),
      child: child,
    );
  }
}

/// Shrinks slightly while held down.
///
/// The app's tappable surfaces are mostly GestureDetector + Container, which
/// gives no feedback at all between the tap and whatever it triggers — on a
/// slow connection that reads as a dead button and gets tapped again. A
/// 3% scale is enough to register as "received" without being a bounce.
class PressableScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double pressedScale;

  const PressableScale({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.pressedScale = 0.97,
  });

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v && mounted) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null || widget.onLongPress != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      onTapDown:   enabled ? (_) => _set(true)  : null,
      onTapUp:     enabled ? (_) => _set(false) : null,
      onTapCancel: enabled ? ()  => _set(false) : null,
      child: AnimatedScale(
        scale: _down && !BrokaMotion.reduced(context)
            ? widget.pressedScale : 1.0,
        duration: BrokaMotion.instant,
        curve: BrokaMotion.enter,
        child: widget.child,
      ),
    );
  }
}

/// Skeleton placeholder with a travelling sheen.
///
/// Replaces a centred spinner. A spinner says "something is happening
/// somewhere"; a skeleton says "this is what is coming and roughly how much
/// of it", which makes the same wait feel shorter and stops the layout
/// jumping when content lands.
///
/// Falls back to a static block under reduce-motion — the shape is doing
/// most of the work; the sheen is garnish.
class ShimmerBox extends StatefulWidget {
  final double? width;
  final double height;
  final BorderRadius radius;

  const ShimmerBox({
    super.key,
    this.width,
    required this.height,
    this.radius = const BorderRadius.all(Radius.circular(10)),
  });

  @override
  State<ShimmerBox> createState() => _ShimmerBoxState();
}

class _ShimmerBoxState extends State<ShimmerBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this, duration: const Duration(milliseconds: 1250))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = ClipRRect(
      borderRadius: widget.radius,
      child: Container(
        width: widget.width,
        height: widget.height,
        color: BrokaColors.bgCard,
      ),
    );
    if (BrokaMotion.reduced(context)) return base;

    return ClipRRect(
      borderRadius: widget.radius,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) => ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (rect) => LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: const [
              Colors.transparent,
              Color(0x228B5CF6),
              Colors.transparent,
            ],
            // Sweeps from fully off-screen left to fully off-screen right,
            // so the sheen never appears to start or stop mid-block.
            stops: [
              (_c.value * 2 - 1).clamp(0.0, 1.0),
              _c.value.clamp(0.0, 1.0),
              (_c.value * 2).clamp(0.0, 1.0),
            ],
          ).createShader(rect),
          child: base,
        ),
      ),
    );
  }
}
