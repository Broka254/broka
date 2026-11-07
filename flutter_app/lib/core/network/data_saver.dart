// Data saver - Settings' switch for people on a small mobile bundle.
//
// The app is already careful with data by default (conditional polls, a disk
// cache for every picture, photos shrunk before upload). This is the extra
// step a user chooses: pictures stop at the size a card already downloaded
// (the product page reuses the card's photo instead of fetching a bigger
// one) and the background sweep checks less often while nothing is
// happening. Nothing stops working; it is only slower to look its sharpest.
//
// Kept on the phone, not the account: a phone on Wi-Fi at home and the same
// account on a bundle elsewhere want different answers.
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class DataSaver {
  DataSaver._();

  /// Settings' switch, live. Off until the user turns it on.
  static final ValueNotifier<bool> enabled = ValueNotifier<bool>(false);

  static bool get isOn => enabled.value;

  static const _key = 'data_saver_on';
  static bool _loaded = false;

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      enabled.value = prefs.getBool(_key) ?? false;
    } catch (_) {}
  }

  static Future<void> setEnabled(bool on) async {
    enabled.value = on;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_key, on);
    } catch (_) {}
  }

  /// Forget what was loaded, for a test that sets the preference itself.
  @visibleForTesting
  static void reset() {
    _loaded = false;
    enabled.value = false;
  }
}
