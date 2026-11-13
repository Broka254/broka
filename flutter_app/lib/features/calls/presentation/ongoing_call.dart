// A call carries on while the user uses the rest of the app (asked for
// 2026-11-13, beside a screenshot of WhatsApp's call screen and its
// minimise button).
//
// The call screen used to be the only place a call could live: leaving it -
// Back, or opening anything else - disposed it, and disposing it hung up.
// Now the screen's minimise button (and Back, while the call is live) puts
// the screen the user came from back on top of it, with the call screen
// kept alive underneath, and a bar across the top of every screen says a
// call is on and brings it back with a tap - or mutes or ends it.
//
// The call screen still owns the call (voip_call_screen.dart); this only
// knows where its route is, what to show in the bar, and how to reach it.
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../main.dart' show BrokaColors;
import '../../../widgets/broka_image.dart';
import '../../../widgets/chat_parts.dart' show kChatGradient;

/// What the bar shows about the call.
@immutable
class OngoingCallInfo {
  const OngoingCallInfo({
    required this.peerName,
    this.peerPhoto,
    required this.status,
    this.isVideo = false,
    this.connected = false,
    this.muted = false,
    this.canMute = false,
  });

  final String peerName;
  final String? peerPhoto;

  /// The call screen's own words: "Calling…", "Ringing…", "02:14"...
  final String status;
  final bool isVideo;
  final bool connected;
  final bool muted;
  final bool canMute;

  @override
  bool operator ==(Object other) =>
      other is OngoingCallInfo &&
      other.peerName == peerName &&
      other.peerPhoto == peerPhoto &&
      other.status == status &&
      other.isVideo == isVideo &&
      other.connected == connected &&
      other.muted == muted &&
      other.canMute == canMute;

  @override
  int get hashCode =>
      Object.hash(peerName, peerPhoto, status, isVideo, connected, muted, canMute);
}

class OngoingCall extends ChangeNotifier {
  OngoingCall._();

  static final OngoingCall instance = OngoingCall._();

  /// In MaterialApp.navigatorObservers: the minimise needs the route
  /// under the call screen, which a Navigator does not say.
  final NavigatorObserver observer = _CallRouteObserver();

  Route<dynamic>? _route;
  NavigatorState? _navigator;
  OngoingCallInfo? _info;
  VoidCallback? _hangUp;
  VoidCallback? _toggleMute;
  // The screen the minimise took from under the call and opened above it.
  RouteSettings? _movedAbove;

  /// A call screen is open, on top or underneath.
  bool get active => _route?.isActive ?? false;

  /// A call screen is open under the screen the user is on.
  bool get minimized => active && !(_route?.isCurrent ?? true);

  OngoingCallInfo? get info => _info;

  /// The call screen, once it has its route. A later call's screen (a
  /// redial, opened over the call it replaced) takes over.
  void attach(
    Route<dynamic> route,
    NavigatorState navigator, {
    required VoidCallback hangUp,
    required VoidCallback toggleMute,
  }) {
    _route = route;
    _navigator = navigator;
    _hangUp = hangUp;
    _toggleMute = toggleMute;
    _movedAbove = null;
    _notifySoon();
  }

  /// Its screen closed. Only that screen's: a replaced call's screen
  /// closing must not take the redial's bar away.
  void detach(Route<dynamic> route) {
    if (!identical(_route, route)) return;
    _route = null;
    _navigator = null;
    _info = null;
    _hangUp = null;
    _toggleMute = null;
    _notifySoon();
  }

  /// The call screen, as it builds: what the bar says.
  void publish(Route<dynamic> route, OngoingCallInfo info) {
    if (!identical(_route, route) || info == _info) return;
    _info = info;
    _notifySoon();
  }

  /// Back to the app, the call carrying on underneath. The screen under
  /// the call - the chat it was placed from, most often - is opened again
  /// above it (a Navigator can't reorder its routes); with none that can
  /// be, Home.
  void minimize() {
    final nav = _navigator;
    final route = _route;
    if (nav == null || route == null || !route.isCurrent) return;
    final below = (observer as _CallRouteObserver).pageBelow(route);
    final name = below?.settings.name;
    if (below != null && name != null && _reopenable(name)) {
      _movedAbove = below.settings;
      nav.removeRoute(below);
      nav.pushNamed(name, arguments: below.settings.arguments);
    } else {
      _movedAbove = null;
      nav.pushNamed('/home');
    }
  }

  static bool _reopenable(String name) =>
      name.startsWith('/') && !const {'/', '/splash', '/auth', '/voip-call'}.contains(name);

  /// The bar was tapped: everything opened over the call is closed.
  void returnToCall() {
    final nav = _navigator;
    final route = _route;
    if (nav == null || route == null || !route.isActive || route.isCurrent) return;
    nav.popUntil((r) => identical(r, route));
  }

  void hangUp() => _hangUp?.call();
  void toggleMute() => _toggleMute?.call();

  /// The call ended with its screen on top: the screen the minimise moved
  /// above it is no longer there (returning to the call closed it), so
  /// closing the call screen should open it again rather than reveal what
  /// was under it. Null when nothing was moved, or it is still open.
  RouteSettings? restoreAfter(Route<dynamic> route) {
    if (!identical(_route, route)) return null;
    final moved = _movedAbove;
    if (moved == null) return null;
    final stillOpen = (observer as _CallRouteObserver).routes.any((r) =>
        r.settings.name == moved.name && identical(r.settings.arguments, moved.arguments));
    return stillOpen ? null : moved;
  }

  bool _notifyScheduled = false;

  // Never during a build: attach and publish are called from the call
  // screen's didChangeDependencies and build.
  void _notifySoon() {
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _notifyScheduled = false;
      notifyListeners();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  @visibleForTesting
  void debugReset() {
    _route = null;
    _navigator = null;
    _info = null;
    _hangUp = null;
    _toggleMute = null;
    _movedAbove = null;
    (observer as _CallRouteObserver).routes.clear();
  }
}

class _CallRouteObserver extends NavigatorObserver {
  final List<Route<dynamic>> routes = [];

  /// The nearest page under [route] - not a dialog or a sheet - when it is
  /// directly under it.
  Route<dynamic>? pageBelow(Route<dynamic> route) {
    final i = routes.indexOf(route);
    if (i <= 0) return null;
    final below = routes[i - 1];
    return below is PageRoute ? below : null;
  }

  void _changed() => OngoingCall.instance._notifySoon();

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    routes.add(route);
    _changed();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    routes.remove(route);
    _changed();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    routes.remove(route);
    _changed();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final i = oldRoute == null ? -1 : routes.indexOf(oldRoute);
    if (newRoute != null) {
      if (i >= 0) {
        routes[i] = newRoute;
      } else {
        routes.add(newRoute);
      }
    } else if (i >= 0) {
      routes.removeAt(i);
    }
    _changed();
  }
}

/// Above the whole app (MaterialApp.builder): while a call is minimised,
/// a bar across the top - under the status bar, pushing every screen down
/// rather than covering its header, as WhatsApp's does.
class OngoingCallHost extends StatelessWidget {
  const OngoingCallHost({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: OngoingCall.instance,
        builder: (context, _) {
          final call = OngoingCall.instance;
          final info = call.info;
          final show = call.minimized && info != null;
          final media = MediaQuery.of(context);
          // The same tree whether or not the bar shows: the app below must
          // never be rebuilt from scratch (its screens would lose their
          // state) just because a call was minimised.
          return Column(children: [
            AnimatedSize(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              alignment: Alignment.topCenter,
              child: show
                  ? OngoingCallBar(info: info, topInset: media.padding.top)
                  : const SizedBox(width: double.infinity),
            ),
            Expanded(
              child: MediaQuery(
                data: show ? media.removePadding(removeTop: true) : media,
                child: child,
              ),
            ),
          ]);
        },
      );
}

class OngoingCallBar extends StatefulWidget {
  const OngoingCallBar({super.key, required this.info, this.topInset = 0});

  final OngoingCallInfo info;
  final double topInset;

  @override
  State<OngoingCallBar> createState() => _OngoingCallBarState();
}

class _OngoingCallBarState extends State<OngoingCallBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))
        ..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;
    final live = info.connected ? BrokaColors.neonGreen : BrokaColors.neonCyan;
    return Material(
      type: MaterialType.transparency,
      child: Semantics(
        button: true,
        label: 'Return to the call with ${info.peerName}',
        child: GestureDetector(
          key: const Key('ongoing-call-bar'),
          behavior: HitTestBehavior.opaque,
          onTap: OngoingCall.instance.returnToCall,
          child: Container(
            width: double.infinity,
            padding: EdgeInsets.fromLTRB(14, widget.topInset + 6, 8, 8),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  Color.lerp(BrokaColors.bg, kChatGradient.first, 0.55)!,
                  Color.lerp(BrokaColors.bg, kChatGradient.last, 0.55)!,
                ],
              ),
              border: Border(bottom: BorderSide(color: live.withOpacity(0.55))),
              boxShadow: [BoxShadow(color: kChatGradient.first.withOpacity(0.35), blurRadius: 18)],
            ),
            child: Row(children: [
              // The face, with a ring that breathes while the call is on.
              AnimatedBuilder(
                animation: _pulse,
                builder: (_, child) => Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: live.withOpacity(0.45 + 0.55 * _pulse.value), width: 1.6),
                    boxShadow: [BoxShadow(color: live.withOpacity(0.35 * _pulse.value), blurRadius: 10)],
                  ),
                  child: child,
                ),
                child: ClipOval(
                  child: SizedBox(
                    width: 30, height: 30,
                    child: BrokaImage(info.peerPhoto, fit: BoxFit.cover,
                        placeholder: _initial(info.peerName)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Row(children: [
                    Icon(info.isVideo ? Icons.videocam_rounded : Icons.call_rounded, size: 13, color: live),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text('${info.peerName} · ${info.status}',
                          maxLines: 1, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white, fontSize: 13,
                              fontWeight: FontWeight.w800,
                              fontFeatures: [FontFeature.tabularFigures()])),
                    ),
                  ]),
                  const SizedBox(height: 1),
                  Text('Tap to return to the call',
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: Colors.white.withOpacity(0.72), fontSize: 11)),
                ]),
              ),
              if (info.canMute)
                _BarButton(
                  key: const Key('ongoing-call-mute'),
                  icon: info.muted ? Icons.mic_off_rounded : Icons.mic_rounded,
                  tooltip: info.muted ? 'Unmute' : 'Mute',
                  color: info.muted ? BrokaColors.warning : Colors.white,
                  onTap: OngoingCall.instance.toggleMute,
                ),
              _BarButton(
                key: const Key('ongoing-call-end'),
                icon: Icons.call_end_rounded,
                tooltip: 'End call',
                color: Colors.white,
                fill: BrokaColors.danger,
                onTap: OngoingCall.instance.hangUp,
              ),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _initial(String name) => DecoratedBox(
        decoration: const BoxDecoration(gradient: LinearGradient(colors: kChatGradient)),
        child: Center(
          child: Text(name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase(),
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 13)),
        ),
      );
}

class _BarButton extends StatelessWidget {
  const _BarButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onTap,
    this.fill,
  });

  final IconData icon;
  final String tooltip;
  final Color color;
  final Color? fill;
  final VoidCallback onTap;

  // Semantics, not a Tooltip: the bar is above the Navigator, where there
  // is no Overlay for a tooltip to open in.
  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: tooltip,
        excludeSemantics: true,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            width: 36, height: 36,
            margin: const EdgeInsets.only(left: 6),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: fill ?? Colors.white.withOpacity(0.12),
              border: fill == null ? Border.all(color: Colors.white.withOpacity(0.25)) : null,
              boxShadow: fill == null ? null : [BoxShadow(color: fill!.withOpacity(0.5), blurRadius: 10)],
            ),
            child: Icon(icon, size: 18, color: color),
          ),
        ),
      );
}
