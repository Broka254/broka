// BROKA - On-device vault for settled chat photos.
//
// The message cache used to slim large data URIs to an empty placeholder, so
// a photo opened offline rendered as a broken-image icon. Instead, data URIs
// are materialised into this vault (app-owned directory, keyed by server
// message id with the phone's client id as fallback) and the cache keeps
// only the small file:// reference: the cache stays small AND the picture
// still renders with no connection.
//
// At most [_maxFiles] photos stay on the phone; the oldest go first.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class ChatMediaVault {
  ChatMediaVault._();

  static String? _dirPath; // warmed for sync render-time lookups

  static Future<Directory> _dir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/chat_media');
    if (!await dir.exists()) await dir.create(recursive: true);
    _dirPath = dir.path;
    return dir;
  }

  static String _safe(String key) =>
      key.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  /// At most this many photos stay on the phone; the oldest go first.
  @visibleForTesting
  static const maxFiles = 200;

  static Iterable<String> _keys(String? messageId, String? clientId) sync* {
    if (messageId != null && messageId.isNotEmpty) yield messageId;
    if (clientId != null && clientId.isNotEmpty) yield clientId;
  }

  /// Synchronous render-time lookup - a stat call, no async, so bubbles
  /// can prefer the on-device copy at build time.
  static File? fileForSync({String? messageId, String? clientId}) {
    try {
      final dir = _dirPath;
      if (dir == null) return null;
      for (final key in _keys(messageId, clientId)) {
        for (final ext in ['jpg', 'png']) {
          final f = File('$dir/${_safe(key)}.$ext');
          if (f.existsSync()) return f;
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static Future<String?> storeBytes(
      {String? messageId,
      String? clientId,
      required Uint8List bytes,
      required String ext}) async {
    final keys = _keys(messageId, clientId).toList();
    if (keys.isEmpty) return null;
    try {
      final dir = await _dir();
      final path =
          '${dir.path}/${_safe(keys.first)}.${ext == 'png' ? 'png' : 'jpg'}';
      await File(path).writeAsBytes(bytes, flush: true);
      unawaited(prune());
      return 'file://$path';
    } catch (_) {
      return null;
    }
  }

  static Future<String?> storeDataUri(
      {String? messageId,
      String? clientId,
      required String dataUri}) async {
    try {
      final comma = dataUri.indexOf(',');
      if (comma < 0) return null;
      final bytes = base64Decode(dataUri.substring(comma + 1));
      final head = dataUri.substring(0, comma);
      return storeBytes(
          messageId: messageId,
          clientId: clientId,
          bytes: bytes,
          ext: head.contains('png') ? 'png' : 'jpg');
    } catch (_) {
      return null;
    }
  }

  /// Copy a staged outbox file into the vault under the settled message id
  /// (falling back to the client id). Call BEFORE the outbox copy is
  /// deleted on confirm.
  static Future<void> adoptFile(File from,
      {String? messageId, String? clientId}) async {
    try {
      final dir = await _dir();
      final keys = _keys(messageId, clientId).toList();
      if (keys.isEmpty) return;
      final ext = from.path.endsWith('.png') ? 'png' : 'jpg';
      await from.copy('${dir.path}/${_safe(keys.first)}.$ext');
      unawaited(prune());
    } catch (_) {}
  }

  static Future<void> remove({String? messageId, String? clientId}) async {
    try {
      final dir = await _dir();
      for (final key in _keys(messageId, clientId)) {
        for (final ext in ['jpg', 'png']) {
          final f = File('${dir.path}/${_safe(key)}.$ext');
          if (await f.exists()) await f.delete();
        }
      }
    } catch (_) {}
  }

  static Future<void> prune() async {
    try {
      final dir = await _dir();
      final files = <File>[];
      await for (final e in dir.list()) {
        if (e is File) files.add(e);
      }
      if (files.length <= maxFiles) return;
      files.sort((a, b) {
        final byTime = a.lastModifiedSync().compareTo(b.lastModifiedSync());
        // Files stamped in the same instant still need a stable order, or
        // the cap would evict an arbitrary photo instead of the oldest.
        return byTime != 0 ? byTime : a.path.compareTo(b.path);
      });
      for (var i = 0; i < files.length - maxFiles; i++) {
        try {
          await files[i].delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// The media URL a cached message should keep: the on-device vault copy
  /// when one exists, a freshly materialised one for data URIs, the remote
  /// URL when it is small enough to keep as text, or '' when a large
  /// remote URL would bloat the cache (it re-fetches with history).
  static Future<String> cacheMediaUrl(
      {required String url,
      String? messageId,
      String? clientId,
      int budget = 50 * 1024}) async {
    if (url.isEmpty || url.startsWith('file://')) return url;
    final vault = fileForSync(messageId: messageId, clientId: clientId);
    if (vault != null) return 'file://${vault.path}';
    if (url.startsWith('data:')) {
      return await storeDataUri(
              messageId: messageId, clientId: clientId, dataUri: url) ??
          (url.length > budget ? '' : url);
    }
    return url.length > budget ? '' : url;
  }
}
