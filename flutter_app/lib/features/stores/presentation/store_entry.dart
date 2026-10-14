// Where "My Store" / "Open an online store" buttons go.
//
// Someone with a store goes to My Store. Someone without one sees the
// explainer the first time (it's the introduction), and My Store's own
// "set up your store" page after that.
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/utils/result.dart';
import '../data/repositories/stores_repository.dart';

class StoreEntry {
  StoreEntry._();

  static const _explainerSeenKey = 'store_explainer_seen';

  static Future<void> markExplainerSeen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_explainerSeenKey, true);
    } catch (_) {}
  }

  static Future<bool> _explainerSeen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_explainerSeenKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Opens My Store, or the explainer for a first-time visitor who has no
  /// store yet.
  static Future<void> open(BuildContext context, {StoresRepository? repository}) async {
    final navigator = Navigator.of(context);
    if (!await _explainerSeen()) {
      final mine = await (repository ?? storesRepository).getMyStore();
      final hasStore = mine.fold(onSuccess: (s) => s != null, onFailure: (_, __) => false);
      if (!hasStore) {
        await navigator.pushNamed('/store-explainer');
        return;
      }
    }
    await navigator.pushNamed('/store-manage');
  }
}
