// BROKA - Local Chat Store
//
// Caches chat threads on-device (SharedPreferences-backed) so a
// conversation is still visible the instant a screen opens - even with
// no network connection at all - the same way WhatsApp shows your message
// history immediately, before it finishes syncing anything.
//
// This is a CACHE, not a replacement for the backend: the server remains
// the single source of truth whenever the device is online. The pattern
// each screen follows is:
//   1. On open, load the cached copy for this thread and render it right
//      away (works fully offline).
//   2. Fetch fresh data from the network in the background; on success,
//      replace what's on screen AND overwrite the cache.
//   3. On send, if the network call fails, keep the outgoing message
//      visible (marked as not-yet-sent) instead of losing it, and store it
//      in a small per-thread outbox so it isn't lost across app restarts
//      either; screens can retry the outbox next time they successfully
//      load history.
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class LocalChatStore {
  static String _key(String scope) => 'chat_cache_v1_$scope';
  static String _outboxKey(String scope) => 'chat_outbox_v1_$scope';

  /// Shared cache scope for the top-level inbox thread list - used by both
  /// InboxScreen (to render instantly offline) and GlobalPollerService
  /// (which keeps this slot warm in the background every ~7s while the app
  /// is alive, since it already fetches the same data for notifications).
  static const String inboxListScope = 'inbox_list';

  /// Cap how many messages we persist per thread so a very long-lived
  /// conversation can't make the on-device cache grow without bound.
  static const int _maxCached = 300;

  /// Load the last-cached messages for [scope] (already-decoded JSON maps -
  /// callers reconstruct their own Message/ChatMessage via fromJson).
  /// Returns an empty list if nothing is cached yet or on any error - a
  /// cache miss should never be treated as a real error by the caller.
  static Future<List<Map<String, dynamic>>> load(String scope) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key(scope));
      if (raw == null || raw.isEmpty) return [];
      final decoded = jsonDecode(raw) as List;
      return decoded.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  /// Persist the latest known message list for [scope]. Best-effort/fire-
  /// and-forget - a caching failure should never block the UI.
  static Future<void> save(String scope, List<Map<String, dynamic>> messages) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final toStore = messages.length > _maxCached
          ? messages.sublist(messages.length - _maxCached)
          : messages;
      await prefs.setString(_key(scope), jsonEncode(toStore));
    } catch (_) {}
  }

  static Future<void> clear(String scope) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key(scope));
    } catch (_) {}
  }

  // ── Outbox: messages typed while offline / that failed to send ──────────
  // Kept separately from the main cache so a failed send is never silently
  // dropped, and so screens can show a clear "not sent yet" affordance and
  // retry later without re-typing.

  static Future<List<Map<String, dynamic>>> loadOutbox(String scope) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_outboxKey(scope));
      if (raw == null || raw.isEmpty) return [];
      final decoded = jsonDecode(raw) as List;
      return decoded.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveOutbox(String scope, List<Map<String, dynamic>> pending) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (pending.isEmpty) {
        await prefs.remove(_outboxKey(scope));
      } else {
        await prefs.setString(_outboxKey(scope), jsonEncode(pending));
      }
    } catch (_) {}
  }
}
