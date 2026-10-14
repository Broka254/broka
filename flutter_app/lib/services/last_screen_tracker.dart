// BROKA - Last Screen Tracker
// Persists a lightweight descriptor of the most recently visited screen
// (route name + small JSON of primitive args, e.g. a listing ID) so the app
// can return the user to where they left off after a relaunch, instead of
// always reopening to the home feed.
//
// Design choice: we deliberately do NOT serialize full objects (e.g. a
// Listing). Screens that need rich data (ProductScreen, NegotiateScreen,
// NegotiationScreen) already know how to re-fetch by ID via the API, so we
// only persist primitive identifiers and let each screen's existing loader
// do the rest. This avoids stale/out-of-date cached data on restore.

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class LastScreenTracker {
  static const _routeKey = 'last_screen_route';
  static const _argsKey  = 'last_screen_args';

  // Routes that make sense to restore. Anything not in this list (auth,
  // splash, voip-call mid-flow, etc.) is intentionally never persisted.
  static const Set<String> restorableRoutes = {
    '/home',
    '/product',
    '/negotiate',
    '/direct-chat',
    '/inbox',
    '/seller-dashboard',
    '/profile',
  };

  /// Call this whenever a restorable screen is entered, with only
  /// JSON-primitive args (String/num/bool/null - no model objects).
  static Future<void> save(String route, [Map<String, dynamic>? args]) async {
    if (!restorableRoutes.contains(route)) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_routeKey, route);
      await prefs.setString(_argsKey, jsonEncode(args ?? {}));
    } catch (_) {
      // Non-fatal - worst case the user just lands on home instead.
    }
  }

  /// Returns (route, args) of the last visited screen, or null if none was
  /// saved (e.g. first-ever launch).
  static Future<({String route, Map<String, dynamic> args})?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final route = prefs.getString(_routeKey);
      if (route == null) return null;
      final rawArgs = prefs.getString(_argsKey);
      final args = rawArgs != null
          ? jsonDecode(rawArgs) as Map<String, dynamic>
          : <String, dynamic>{};
      return (route: route, args: args);
    } catch (_) {
      return null;
    }
  }

  static Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_routeKey);
      await prefs.remove(_argsKey);
    } catch (_) {}
  }
}
