// Where ScreenCache keeps its entries.
//
// Production keeps one small JSON file per entry under the app's cache
// directory, one folder per account: SharedPreferences loads its whole store
// into memory at startup and rewrites it on every write, which is fine for a
// token and a few flags and wrong for pages of listings. Files in the cache
// directory are also the OS's to reclaim under storage pressure, which is
// what a cache should be.
//
// Tests get NullCacheStore unless they install one (ScreenCache.debugInstall):
// the widget tests open the same screen several times with different fake
// backends, and a cache that silently carried one test's answers into the
// next would make them pass or fail on test order.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Storage for cache entries, addressed by account folder and entry name.
abstract class CacheStore {
  Future<String?> read(String account, String name);
  Future<void> write(String account, String name, String value);
  Future<void> delete(String account, String name);

  /// Removes everything kept for [account] - sign-out, account switch.
  Future<void> deleteAccount(String account);

  /// Removes everything.
  Future<void> clear();
}

/// Keeps nothing. Every read is a miss.
class NullCacheStore implements CacheStore {
  const NullCacheStore();
  @override
  Future<String?> read(String account, String name) async => null;
  @override
  Future<void> write(String account, String name, String value) async {}
  @override
  Future<void> delete(String account, String name) async {}
  @override
  Future<void> deleteAccount(String account) async {}
  @override
  Future<void> clear() async {}
}

/// In memory only - for tests, and as the shape the other stores follow.
class MemoryCacheStore implements CacheStore {
  final Map<String, Map<String, String>> _accounts = {};

  /// Every entry, for tests to look at: account -> name -> raw JSON.
  Map<String, Map<String, String>> get debugEntries => _accounts;

  @override
  Future<String?> read(String account, String name) async => _accounts[account]?[name];

  @override
  Future<void> write(String account, String name, String value) async {
    _accounts.putIfAbsent(account, () => {})[name] = value;
  }

  @override
  Future<void> delete(String account, String name) async {
    _accounts[account]?.remove(name);
  }

  @override
  Future<void> deleteAccount(String account) async {
    _accounts.remove(account);
  }

  @override
  Future<void> clear() async => _accounts.clear();
}

/// One file per entry: `<root>/<account>/<name>.json`.
class FileCacheStore implements CacheStore {
  FileCacheStore(this._rootProvider);

  /// Resolved lazily: path_provider needs the binding, and the first screen
  /// that reads the cache is well after it exists.
  final Future<Directory> Function() _rootProvider;
  Future<Directory>? _root;

  Future<Directory> get _rootDir => _root ??= _rootProvider();

  /// Folder and file names are built only from [A-Za-z0-9_-]: ids come from
  /// the server and a filter can hold anything the user typed.
  static String safe(String s) => s.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  Future<File> _file(String account, String name) async {
    final root = await _rootDir;
    return File('${root.path}/${safe(account)}/${safe(name)}.json');
  }

  @override
  Future<String?> read(String account, String name) async {
    try {
      final f = await _file(account, name);
      if (!await f.exists()) return null;
      return await f.readAsString();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String account, String name, String value) async {
    try {
      final f = await _file(account, name);
      await f.parent.create(recursive: true);
      // Written beside the entry and renamed over it: a crash mid-write
      // leaves the old entry or the new one, never half of one.
      final tmp = File('${f.path}.tmp');
      await tmp.writeAsString(value, flush: true);
      await tmp.rename(f.path);
    } catch (_) {}
  }

  @override
  Future<void> delete(String account, String name) async {
    try {
      final f = await _file(account, name);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  @override
  Future<void> deleteAccount(String account) async {
    try {
      final root = await _rootDir;
      final dir = Directory('${root.path}/${safe(account)}');
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  @override
  Future<void> clear() async {
    try {
      final root = await _rootDir;
      if (await root.exists()) await root.delete(recursive: true);
    } catch (_) {}
  }

  /// Deletes entries not written for [olderThan]. Run once per launch, so a
  /// filter used once a month ago does not keep a file forever.
  Future<void> prune(Duration olderThan) async {
    try {
      final root = await _rootDir;
      if (!await root.exists()) return;
      final cutoff = DateTime.now().subtract(olderThan);
      await for (final e in root.list(recursive: true)) {
        if (e is File && (await e.lastModified()).isBefore(cutoff)) {
          await e.delete();
        }
      }
    } catch (_) {}
  }
}

/// A short, stable name for a set of parameters - FNV-1a, 64 bits as two
/// 32-bit halves so it is the same on every platform. The full key is kept
/// inside the entry and checked on read, so a collision is a miss, never
/// another filter's listings.
String cacheHash(String s) {
  var h1 = 0x811c9dc5;
  var h2 = 0x01000193;
  for (final unit in utf8.encode(s)) {
    h1 = ((h1 ^ unit) * 0x01000193) & 0xffffffff;
    h2 = ((h2 ^ unit) * 0x811c9dc5 + 0x9e3779b9) & 0xffffffff;
  }
  return '${h1.toRadixString(16).padLeft(8, '0')}${h2.toRadixString(16).padLeft(8, '0')}';
}
