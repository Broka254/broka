// BROKA - Connectivity Monitor
//
// Says when the phone's network comes back, so the offline sync
// (MessageSyncService) runs then rather than at the next resume or the next
// Inbox sweep that happens to get through.
//
// Android tells us over `com.broka.app/connectivity` (ConnectivityBridge.kt,
// ConnectivityManager's default-network callback): "online" or "offline",
// once on listening and again on every change. A plain channel rather than
// connectivity_plus: CI builds with Flutter 3.24.5, and connectivity_plus
// 7.x's Android build uses the newer Flutter Gradle plugin DSL that version
// does not have ("Could not get unknown property 'flutter'"), the same break
// that pins geolocator_android in pubspec.yaml.
//
// Elsewhere (iOS, tests) the channel is not there; the sync still runs on
// resume and when the Inbox sweep reaches the server again after failing.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class ConnectivityMonitor {
  ConnectivityMonitor._();
  static final ConnectivityMonitor instance = ConnectivityMonitor._();

  static const EventChannel _channel = EventChannel('com.broka.app/connectivity');

  StreamSubscription<dynamic>? _sub;
  String? _state;
  VoidCallback? _onRestored;

  /// The last state Android reported: "online", "offline", or null.
  String? get state => _state;

  /// Start listening; [onRestored] runs on every offline -> online change.
  void start(VoidCallback onRestored) {
    _onRestored = onRestored;
    if (_sub != null) return;
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      _sub = _channel.receiveBroadcastStream().listen(
        (event) => report(event is String ? event : null),
        onError: (_) {},
        cancelOnError: false,
      );
    } catch (_) {
      _sub = null;
    }
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    _state = null;
    _onRestored = null;
  }

  /// A state from the platform. Public so tests can stand in for Android.
  @visibleForTesting
  void report(String? state) {
    final now = switch (state) {
      'online' => 'online',
      'offline' => 'offline',
      _ => null,
    };
    if (now == null) return;
    final restored = now == 'online' && _state == 'offline';
    _state = now;
    debugPrint('[Sync] NETWORK_${now.toUpperCase()} '
        'at=${DateTime.now().toUtc().toIso8601String()}');
    if (restored) _onRestored?.call();
  }
}
