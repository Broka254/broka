// BROKA - Sell Draft Store
//
// Persists the in-progress "new listing" form (SharedPreferences-backed,
// same approach as LocalChatStore) so it survives the app's process being
// killed and relaunched from scratch.
//
// Why this exists: launching the system camera (image_picker's
// ImageSource.camera, used for every listing photo in the sell flow) hands
// the foreground to a separate app. On a memory-constrained phone, Android
// can - and does - kill BROKA's process while it's in the background to
// reclaim that memory. When the user backs out of the camera, Android
// relaunches BROKA from a cold start: a fresh process, a fresh splash
// screen, and (since Flutter keeps no memory of the old widget tree) the
// entire in-progress listing - every field, every photo already taken -
// is gone, with no way for the app itself to tell the difference between
// "the user just opened the app" and "the user is returning mid-task".
//
// This can't be prevented outright - Android is explicit that any
// backgrounded process may be killed at any time - so instead the draft is
// saved to disk at the highest-risk moments (right before every camera
// launch) and restored automatically the next time the sell wizard opens,
// including via the splash screen's own resume check.
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class SellDraftStore {
  SellDraftStore._();
  static const _key = 'broka_sell_draft_v1';

  static Future<void> save(Map<String, dynamic> draft) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode({
        ...draft,
        'savedAt': DateTime.now().toIso8601String(),
      }));
    } catch (_) {
      // Non-fatal - worst case the draft simply isn't recoverable this time.
    }
  }

  static Future<Map<String, dynamic>?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return null;
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (_) {}
  }

  /// Cheap existence check - avoids decoding the whole draft just to know
  /// there is one.
  static Future<bool> hasDraft() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.containsKey(_key);
    } catch (_) {
      return false;
    }
  }

  /// Whether a draft was saved within [window] of [now] - what the splash
  /// screen reopens the sell wizard for (2026-10-08).
  ///
  /// It used to reopen it for ANY draft. A draft lives until the listing
  /// is published or the seller taps Start over, so a seller who walked
  /// away from one landed on the Photos step every time they opened BROKA
  /// - for as long as the draft existed - with no Home under it to go back
  /// to. A fresh draft means the app was killed mid-listing (the camera,
  /// M-Pesa, a call); an older one was left on purpose, and waits behind
  /// the Sell button instead.
  static Future<bool> hasFreshDraft(Duration window, {DateTime? now}) async {
    final draft = await load();
    if (draft == null) return false;
    final savedAt = DateTime.tryParse(draft['savedAt'] as String? ?? '');
    if (savedAt == null) return false;
    final age = (now ?? DateTime.now()).difference(savedAt);
    return !age.isNegative && age < window;
  }
}
