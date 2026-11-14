// Where a minimised call lives (services/call_dock.dart): above every
// screen, below nothing. Wraps the app's navigator in MaterialApp.builder,
// as ZenoSessionHost does.
//
// The pill can be dragged anywhere and settles against the nearer side, so
// it never sits over what the user came to read. It starts at the top left,
// where WhatsApp's minimise button was - the place the user's eye already is.
import 'package:flutter/material.dart';

import '../services/call_dock.dart';

class CallDockHost extends StatefulWidget {
  const CallDockHost({super.key, required this.child});

  final Widget child;

  @override
  State<CallDockHost> createState() => _CallDockHostState();
}

class _CallDockHostState extends State<CallDockHost> {
  final _dock = CallDock.instance;

  /// The pill's top-left corner, or null for its starting place.
  Offset? _at;
  Size _pillSize = const Size(240, 64);
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    _dock.attachHost();
    _dock.addListener(_changed);
  }

  @override
  void dispose() {
    _dock.removeListener(_changed);
    _dock.detachHost();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Offset _clamp(Offset o, Size screen, EdgeInsets pad) {
    final maxX = screen.width - _pillSize.width - 8;
    final maxY = screen.height - pad.bottom - _pillSize.height - 8;
    return Offset(
      o.dx.clamp(8.0, maxX < 8 ? 8.0 : maxX),
      o.dy.clamp(pad.top + 6, maxY < pad.top + 6 ? pad.top + 6 : maxY),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pill = _dock.pill;
    final mq = MediaQuery.of(context);
    final screen = mq.size;
    final pad = mq.padding;
    final at = _clamp(_at ?? Offset(12, pad.top + 8), screen, pad);
    return Stack(fit: StackFit.expand, children: [
      widget.child,
      if (pill != null)
        AnimatedPositioned(
          duration: _dragging ? Duration.zero : const Duration(milliseconds: 260),
          curve: Curves.easeOutCubic,
          left: at.dx,
          top: at.dy,
          child: GestureDetector(
            onPanStart: (_) => setState(() {
              _dragging = true;
              _at = at;
            }),
            onPanUpdate: (d) => setState(() => _at = _clamp((_at ?? at) + d.delta, screen, pad)),
            onPanEnd: (_) => setState(() {
              _dragging = false;
              // Against the nearer side, out of the way of what's under it.
              final x = (_at ?? at).dx + _pillSize.width / 2 < screen.width / 2
                  ? 8.0
                  : screen.width - _pillSize.width - 8;
              _at = _clamp(Offset(x, (_at ?? at).dy), screen, pad);
            }),
            child: _Measured(
              onSize: (s) {
                if (s != _pillSize) setState(() => _pillSize = s);
              },
              // A Material, so the call's text and ink have one up here,
              // above the navigator's pages.
              child: Material(
                type: MaterialType.transparency,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: screen.width - 16),
                  child: pill,
                ),
              ),
            ),
          ),
        ),
    ]);
  }
}

/// Reports its child's size after layout.
class _Measured extends StatefulWidget {
  const _Measured({required this.child, required this.onSize});
  final Widget child;
  final ValueChanged<Size> onSize;

  @override
  State<_Measured> createState() => _MeasuredState();
}

class _MeasuredState extends State<_Measured> {
  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = context.findRenderObject();
      if (box is RenderBox && box.hasSize) widget.onSize(box.size);
    });
    return widget.child;
  }
}
