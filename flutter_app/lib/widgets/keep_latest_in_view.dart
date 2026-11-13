// Keeps the newest message in view when a chat's message area gets shorter.
//
// The chat lists are chronological (oldest at the top) on a plain
// ScrollController. When the keyboard opened, the Scaffold shrank the list's
// viewport by the keyboard's height but the scroll offset stayed where it
// was - so the last messages, which had been at the bottom, slid under the
// composer and the keyboard, and stayed there until the next message
// arrived. The same happened, by a smaller amount, when the reply preview or
// the typing line appeared above the composer.
//
// This follows the bottom while the viewport shrinks, every frame of the
// keyboard's animation, but only for a reader who was at the newest
// messages: someone scrolled up to read an old one is left where they are.
import 'package:flutter/widgets.dart';

class KeepLatestInView extends StatefulWidget {
  const KeepLatestInView({
    super.key,
    required this.controller,
    required this.child,
    this.slack = 48,
  });

  /// The controller of the scrollable [child].
  final ScrollController controller;

  /// A chat's message list.
  final Widget child;

  /// How far from the very bottom still counts as reading the latest: the
  /// last bubble's timestamp line, roughly.
  final double slack;

  @override
  State<KeepLatestInView> createState() => _KeepLatestInViewState();
}

class _KeepLatestInViewState extends State<KeepLatestInView> {
  /// Whether the reader was at the newest messages, as of the last scroll
  /// made at the viewport's current height.
  bool _atLatest = true;
  double? _viewport;

  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0) return false;
    final m = n.metrics;
    // A scroll the jump below causes, or one the reader makes, at the
    // height the viewport has now. One reported while the height is still
    // changing says nothing about where the reader meant to be.
    if (_viewport == null || (m.viewportDimension - _viewport!).abs() < 0.5) {
      _atLatest = m.extentAfter <= widget.slack;
    }
    return false;
  }

  bool _onMetrics(ScrollMetricsNotification n) {
    if (n.depth != 0) return false;
    final m = n.metrics;
    final before = _viewport;
    _viewport = m.viewportDimension;
    final shrank = before != null && m.viewportDimension < before - 0.5;
    if (shrank && _atLatest && m.extentAfter > 0) {
      final c = widget.controller;
      if (c.hasClients) c.jumpTo(c.position.maxScrollExtent);
    } else if (before == null) {
      _atLatest = m.extentAfter <= widget.slack;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => NotificationListener<ScrollMetricsNotification>(
        onNotification: _onMetrics,
        child: NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: widget.child,
        ),
      );
}
