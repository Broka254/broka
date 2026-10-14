// BROKA - the face on a notification.
//
// Asked for (2026-10-08): incoming calls, missed calls and messages show the
// selfie of the person calling or writing, as WhatsApp's do. The server
// sends the URL of their profile photo with the push (a picture would not
// fit: FCM carries 4KB); the app's sweep has the photo from the inbox,
// where it may still be an inline base64 selfie. This turns either into
// the notification's large icon: round, small, and cached, so the same
// person's next call or message costs nothing.
//
// Every failure here is "no face", never "no notification": the caller
// waits a bounded time ([load]'s timeout) and posts without one.

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../widgets/broka_image.dart';

class NotificationAvatar {
  NotificationAvatar._();

  /// Pixels across. Android draws the large icon at 64dp at most - 192px
  /// on the densest screens. The server's thumbnail is 480px.
  static const int size = 192;

  // Finished icons for this isolate. The FCM background isolate starts
  // empty each time, hence the disk cache below it.
  static final Map<String, Uint8List> _memory = <String, Uint8List>{};
  static const int _memoryKept = 40;
  static const int _diskKept = 120;

  /// Where downloaded photos are kept between isolates and launches. A
  /// photo's URL names its image asset, and a new photo is a new asset, so
  /// a cached one is never stale. Replaced in tests.
  @visibleForTesting
  static Future<Directory?> Function() cacheDirectory = _defaultCacheDirectory;

  static Future<Directory?> _defaultCacheDirectory() async {
    try {
      final dir = Directory('${(await getTemporaryDirectory()).path}/notification_avatars');
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    } catch (_) {
      return null;
    }
  }

  /// The large icon for [source] - a photo URL, a "/media/..." path, or an
  /// inline base64 selfie - or null when there is none, or it could not be
  /// had within [timeout]. A download cut off by the timeout carries on
  /// and is cached, so the next notification from them has the face.
  static Future<Uint8List?> load(
    String? source, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final s = source?.trim();
    if (s == null || s.isEmpty) return null;
    final key = _key(s);
    final remembered = _memory[key];
    if (remembered != null) return remembered;
    try {
      return await _load(s, key).timeout(timeout);
    } catch (e) {
      debugPrint('[NotificationAvatar] none for this notification: $e');
      return null;
    }
  }

  static Future<Uint8List?> _load(String source, String key) async {
    final raw = await _cached(key) ?? await _fetch(source, key);
    if (raw == null) return null;
    // Round, as every messaging app draws a person. Android shows the
    // large icon as a square (a rounded one from Android 12): the photo
    // itself still beats initials if the crop can't be done here.
    Uint8List? round;
    try {
      round = await circle(raw).timeout(const Duration(seconds: 1));
    } catch (_) {}
    final icon = round ?? raw;
    _memory.remove(key);
    _memory[key] = icon;
    while (_memory.length > _memoryKept) {
      _memory.remove(_memory.keys.first);
    }
    return icon;
  }

  static Future<Uint8List?> _cached(String key) async {
    try {
      final dir = await cacheDirectory();
      if (dir == null) return null;
      final file = File('${dir.path}/$key');
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      return null;
    }
  }

  static Future<Uint8List?> _fetch(String source, String key) async {
    Uint8List? bytes;
    final url = BrokaImage.networkUrl(source);
    if (url != null) {
      final res = await http.get(Uri.parse(url));
      final type = res.headers['content-type'] ?? '';
      // An error page served with 200 is not a face.
      if (res.statusCode != 200 || res.bodyBytes.isEmpty ||
          (type.isNotEmpty && !type.startsWith('image/'))) {
        return null;
      }
      bytes = res.bodyBytes;
    } else {
      bytes = BrokaImage.inlineBytes(source);
    }
    if (bytes == null || bytes.isEmpty) return null;
    unawaited(_store(key, bytes));
    return bytes;
  }

  static Future<void> _store(String key, Uint8List bytes) async {
    try {
      final dir = await cacheDirectory();
      if (dir == null) return;
      await File('${dir.path}/$key').writeAsBytes(bytes, flush: true);
      final files = dir.listSync().whereType<File>().toList();
      if (files.length <= _diskKept) return;
      files.sort((a, b) => a.statSync().modified.compareTo(b.statSync().modified));
      for (final old in files.take(files.length - _diskKept)) {
        try {
          old.deleteSync();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// [encoded] (any format the engine decodes - the server's WebP, a JPEG
  /// selfie) as a [size]-pixel round PNG, centred, or null if it is not an
  /// image.
  @visibleForTesting
  static Future<Uint8List?> circle(Uint8List encoded) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(encoded);
    // Decoded with its short side at [size]: a portrait selfie is cropped
    // to its middle, not squashed.
    final codec = await ui.instantiateImageCodecWithSize(buffer,
        getTargetSize: (w, h) {
      if (w <= 0 || h <= 0) return const ui.TargetImageSize(width: size, height: size);
      final scale = size / (w < h ? w : h);
      return ui.TargetImageSize(
        width: (w * scale).ceil(),
        height: (h * scale).ceil(),
      );
    });
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    const r = size / 2;
    canvas.clipPath(ui.Path()
      ..addOval(ui.Rect.fromCircle(center: const ui.Offset(r, r), radius: r)));
    canvas.drawImage(
      image,
      ui.Offset((size - image.width) / 2, (size - image.height) / 2),
      ui.Paint()..filterQuality = ui.FilterQuality.medium,
    );
    final picture = recorder.endRecording();
    final out = await picture.toImage(size, size);
    final data = await out.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    out.dispose();
    picture.dispose();
    codec.dispose();
    return data?.buffer.asUint8List();
  }

  /// A file name for [source]: FNV-1a, 64 bits - stable across launches,
  /// unlike String.hashCode, and short for a megabyte of inline base64.
  static String _key(String source) {
    var hash = 0xcbf29ce484222325;
    for (final unit in source.codeUnits) {
      hash ^= unit;
      hash *= 0x100000001b3;
    }
    return hash.toUnsigned(64).toRadixString(16).padLeft(16, '0');
  }

  /// Forget the icons held in memory - for tests.
  @visibleForTesting
  static void clearMemory() => _memory.clear();
}
