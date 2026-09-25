// Where the sell wizard keeps its photos until the listing is published.
//
// A camera shot lands in the OS's cache directory, which Android may clear
// whenever storage runs low - and a draft restored after that pointed at
// photos that were gone. Photos are moved into the app's own support
// directory as soon as they're taken, so a draft's photos last as long as
// the draft does, and removed when the listing is published or the draft
// discarded.
import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';

class SellPhotoStore {
  SellPhotoStore._();

  static const _folder = 'sell_draft';

  /// Overridable in tests (there is no platform channel there).
  static Future<Directory> Function() baseDirectory = getApplicationSupportDirectory;

  static Future<Directory?> _dir() async {
    try {
      final dir = Directory('${(await baseDirectory()).path}${Platform.pathSeparator}$_folder');
      if (!dir.existsSync()) await dir.create(recursive: true);
      return dir;
    } catch (_) {
      return null;
    }
  }

  static String _name(String source) {
    final dot = source.lastIndexOf('.');
    final ext = dot == -1 ? '.jpg' : source.substring(dot).toLowerCase();
    final random = Random.secure();
    final id = List.generate(8, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    return '${DateTime.now().millisecondsSinceEpoch}_$id${ext.length > 6 ? '.jpg' : ext}';
  }

  /// A durable copy of [photo]. [moveOriginal] deletes the source (a camera
  /// capture nobody else needs); a gallery pick is copied and left alone.
  /// If the copy can't be made the original is returned - a photo in the
  /// cache is still better than no photo.
  static Future<File> keep(File photo, {bool moveOriginal = false}) async {
    final dir = await _dir();
    if (dir == null || photo.path.startsWith(dir.path)) return photo;
    try {
      final kept = await photo.copy('${dir.path}${Platform.pathSeparator}${_name(photo.path)}');
      if (moveOriginal) {
        try {
          await photo.delete();
        } catch (_) {}
      }
      return kept;
    } catch (_) {
      return photo;
    }
  }

  /// Deletes [photo] if it is one of ours (a photo the seller removed).
  static Future<void> discard(File photo) async {
    final dir = await _dir();
    if (dir == null || !photo.path.startsWith(dir.path)) return;
    try {
      await photo.delete();
    } catch (_) {}
  }

  /// Deletes every kept photo except [keepPaths]. Called once a listing is
  /// published or a draft discarded, so abandoned drafts don't pile up.
  static Future<void> clear({Set<String> keepPaths = const {}}) async {
    final dir = await _dir();
    if (dir == null) return;
    try {
      await for (final entity in dir.list()) {
        if (entity is File && !keepPaths.contains(entity.path)) {
          try {
            await entity.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }
}
