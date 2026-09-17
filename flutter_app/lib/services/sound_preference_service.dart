import 'package:shared_preferences/shared_preferences.dart';

/// Persists the splash boot-sound on/off toggle so the user isn't asked to
/// reconfigure it every time BROKA opens (splash spec §8: "The sound
/// preference should persist so users don't have to repeatedly configure
/// it.").
class SoundPreferenceService {
  SoundPreferenceService._();

  static const _key = 'splash_boot_sound_enabled';

  /// Cached in memory so callers (e.g. the splash screen's first frame)
  /// can read a best-effort value synchronously without waiting on I/O.
  static bool cached = true;

  static Future<bool> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      cached = prefs.getBool(_key) ?? true;
    } catch (_) {
      // Ignore - fall back to the in-memory default (sound on).
    }
    return cached;
  }

  static Future<void> setEnabled(bool enabled) async {
    cached = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_key, enabled);
    } catch (_) {
      // Non-fatal: the preference just won't persist this session.
    }
  }
}
