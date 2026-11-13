import 'package:flutter/widgets.dart';

/// Keeps a chat's newest message in view when the list gets shorter.
///
/// The chats list oldest first, so the newest message is at the bottom of
/// the scroll. When the keyboard opens the Scaffold shrinks the list from
/// the bottom, and a scroll view keeps its offset from the top: the last
/// messages slid under the composer and the keyboard while the user typed
/// a reply to them (reported 2026-11-13, with screenshots). The same
/// happened when a reply preview or the typing indicator appeared above the
/// composer.
///
/// Whenever the visible height of the list shrinks while the user was at
/// the newest message, this jumps back to it - every frame of the
/// keyboard's animation, so the bottom stays put as it slides up. Someone
/// who had scrolled up to read older messages is left where they were.
class KeepLatestInView extends StatefulWidget {
  const KeepLatestInView({
    super.key,
    required this.controller,
    required this.child,
    this.slack = 48,
  });

  /// The list's controller.
  final ScrollController controller;

  /// The list, a vertical scroll view that is not reversed.
  final Widget child;

  /// How far from the bottom still counts as "at the newest message".
  final double slack;

  @override
  State<KeepLatestInView> createState() => _KeepLatestInViewState();
}

class _KeepLatestInViewState extends State<KeepLatestInView> {
  double? _viewport;
  // A chat opens on its newest message.
  bool _atLatest = true;

  bool _isAtLatest(ScrollMetrics m) => m.maxScrollExtent - m.pixels <= widget.slack;

  bool _onNotification(Notification n) {
    if (n is ScrollMetricsNotification) {
      if (n.depth == 0) _metricsChanged(n.metrics);
    } else if (n is ScrollUpdateNotification || n is ScrollEndNotification) {
      // Scrolling - by the user or by the screen's own scroll to a new
      // message - is what says where they are reading.
      final s = n as ScrollNotification;
      if (s.depth == 0) _atLatest = _isAtLatest(s.metrics);
    }
    return false;
  }

  void _metricsChanged(ScrollMetrics m) {
    final before = _viewport;
    _viewport = m.viewportDimension;
    if (before == null || m.viewportDimension >= before - 0.5) return;
    if (!_atLatest) return;
    final c = widget.controller;
    if (!c.hasClients) return;
    final end = c.position.maxScrollExtent;
    if (c.position.pixels < end) c.jumpTo(end);
  }

  @override
  Widget build(BuildContext context) => NotificationListener<Notification>(
        onNotification: _onNotification,
        child: widget.child,
      );
}
