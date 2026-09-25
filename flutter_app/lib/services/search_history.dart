// Home's recent listing searches, kept on the phone.
//
// Lived inside HomeScreen as three methods and a list handed to the search
// page when it opened. The page kept its own copy of that list, so "Clear"
// emptied the stored history while the page went on showing every entry until
// it was closed and opened again. The store is the one owner now, and the
// search screen reads what it returns after each change.
//
// Only a search the user actually made is recorded - pressing search, or
// opening a result - never text that was on its way to being a search.
// Recording on every pause while typing is how "iph", "ipho" and "iphone"
// all ended up in the list.
import 'package:shared_preferences/shared_preferences.dart';

class SearchHistory {
  SearchHistory._();

  /// Same key HomeScreen always used, so existing history survives.
  static const _key = 'search_history';
  static const maxEntries = 10;

  static Future<List<String>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getStringList(_key) ?? const [];
    } catch (_) {
      return const [];
    }
  }

  /// Puts [query] at the top. "iPhone" and "iphone " are one entry: the
  /// newest spelling wins.
  static Future<List<String>> add(String query) async {
    final q = query.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (q.isEmpty) return load();
    final list = [...await load()]
      ..removeWhere((e) => e.toLowerCase() == q.toLowerCase())
      ..insert(0, q);
    if (list.length > maxEntries) list.removeRange(maxEntries, list.length);
    return _save(list);
  }

  static Future<List<String>> remove(String query) async {
    final list = [...await load()]..remove(query);
    return _save(list);
  }

  static Future<List<String>> clear() => _save(const []);

  static Future<List<String>> _save(List<String> list) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (list.isEmpty) {
        await prefs.remove(_key);
      } else {
        await prefs.setStringList(_key, list);
      }
    } catch (_) {}
    return list;
  }
}
