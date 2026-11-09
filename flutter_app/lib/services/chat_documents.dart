// Documents in a direct chat (2026-11-09): picking files to send, keeping
// the ones sent and received on the phone, and opening them.
//
// The picker and the viewer are Android's own, through a small channel in
// MainActivity (ChatDocuments.kt) rather than a plugin - CI builds with a
// pinned Flutter and Android Gradle Plugin, and the share and ringtone
// channels already work this way. A phone without the channel (iOS, which
// BROKA doesn't ship yet) is told documents can't be attached on it.
//
// What a chat accepts is the server's list (backend api/core/chat_files.py):
// the same extensions here, so a file it would refuse is refused before it
// is uploaded, in words, instead of after a wasted upload.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// A file the user picked, copied into the app's cache by the picker.
class PickedDocument {
  const PickedDocument({
    required this.name,
    this.path,
    this.size,
    this.mime,
    this.tooLarge = false,
    this.unreadable = false,
  });

  final String name;

  /// Null when the file was not copied (too large, unreadable).
  final String? path;
  final int? size;
  final String? mime;
  final bool tooLarge;
  final bool unreadable;

  factory PickedDocument.fromMap(Map<dynamic, dynamic> m) => PickedDocument(
        name: (m['name'] as String?)?.trim().isNotEmpty == true
            ? (m['name'] as String).trim()
            : 'document',
        path: m['path'] as String?,
        size: (m['size'] as num?)?.toInt(),
        mime: m['mime'] as String?,
        tooLarge: m['tooLarge'] == true,
        unreadable: m['unreadable'] == true,
      );
}

/// Why opening a document did not work, or that it did.
enum OpenResult { opened, noApp, missing, unsupported }

class ChatDocuments {
  ChatDocuments._();

  static const MethodChannel channel = MethodChannel('com.broka.app/documents');

  /// The server's limit (api/core/chat_files.py MAX_FILE_MB).
  static const int maxBytes = 15 * 1024 * 1024;

  /// At most this many documents in one go.
  static const int maxPerSend = 10;

  /// Extension -> MIME type, the server's list.
  static const Map<String, String> types = {
    'pdf': 'application/pdf',
    'doc': 'application/msword',
    'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls': 'application/vnd.ms-excel',
    'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'ppt': 'application/vnd.ms-powerpoint',
    'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'odt': 'application/vnd.oasis.opendocument.text',
    'ods': 'application/vnd.oasis.opendocument.spreadsheet',
    'odp': 'application/vnd.oasis.opendocument.presentation',
    'rtf': 'application/rtf',
    'txt': 'text/plain',
    'csv': 'text/csv',
  };

  /// What the picker offers. Some file managers call a CSV by its older
  /// name; the server decides what each one is from its bytes anyway.
  static List<String> get pickerTypes =>
      {...types.values, 'text/comma-separated-values'}.toList();

  static String extensionOf(String name) {
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return '';
    return name.substring(dot + 1).toLowerCase();
  }

  static bool accepts(String name) => types.containsKey(extensionOf(name));

  static String mimeFor(String name) =>
      types[extensionOf(name)] ?? 'application/octet-stream';

  /// "PDF", "Word", "Excel"... - what a document is, in a word.
  static String kindLabel(String name) {
    switch (extensionOf(name)) {
      case 'pdf':
        return 'PDF';
      case 'doc':
      case 'docx':
      case 'odt':
      case 'rtf':
        return 'Word';
      case 'xls':
      case 'xlsx':
      case 'ods':
        return 'Excel';
      case 'csv':
        return 'CSV';
      case 'ppt':
      case 'pptx':
      case 'odp':
        return 'PowerPoint';
      case 'txt':
        return 'Text';
      default:
        return 'Document';
    }
  }

  /// "1.2 MB", "640 KB", "512 B".
  static String sizeLabel(int? bytes) {
    if (bytes == null || bytes < 0) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
    final mb = bytes / (1024 * 1024);
    return '${mb < 10 ? mb.toStringAsFixed(1) : mb.round()} MB';
  }

  /// The system picker, several files at once. Null when this phone has no
  /// way to pick documents; an empty list when nothing was picked.
  static Future<List<PickedDocument>?> pick() async {
    try {
      final raw = await channel.invokeMethod<List<dynamic>>('pick', {
        'mimeTypes': pickerTypes,
        'maxBytes': maxBytes,
      });
      return [
        for (final m in raw ?? const [])
          if (m is Map) PickedDocument.fromMap(m),
      ];
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      debugPrint('[ChatDocuments] picker unavailable: ${e.code}');
      return null;
    }
  }

  /// Opens [path] in another app.
  static Future<OpenResult> open(String path, {String? mime}) async {
    try {
      final r = await channel.invokeMethod<String>('open', {'path': path, 'mime': mime});
      switch (r) {
        case 'opened':
          return OpenResult.opened;
        case 'missing':
          return OpenResult.missing;
        default:
          return OpenResult.noApp;
      }
    } on MissingPluginException {
      return OpenResult.unsupported;
    } on PlatformException {
      return OpenResult.noApp;
    }
  }

  // ── On the phone ─────────────────────────────────────────────────────────
  // A sent or downloaded document is kept under the app's documents folder,
  // one folder per message (its server id, else the phone's client id),
  // under its own name: what the viewer app shows as the file's title.

  static String? _rootPath; // warmed for build-time lookups

  static Future<Directory> _root() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/chat_files');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    _rootPath = dir.path;
    return dir;
  }

  /// Resolves the folder once, so [fileForSync] can answer at build time.
  static Future<void> warm() async {
    try {
      await _root();
    } catch (_) {}
  }

  static String _safe(String key) => key.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  static String safeFileName(String name) {
    final cleaned = name
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
        .trim()
        .replaceAll(RegExp(r'^\.+'), '');
    if (cleaned.isEmpty) return 'document';
    return cleaned.length > 120 ? cleaned.substring(cleaned.length - 120) : cleaned;
  }

  static Iterable<String> _keys(String? messageId, String? clientId) sync* {
    if (messageId != null && messageId.isNotEmpty) yield messageId;
    if (clientId != null && clientId.isNotEmpty) yield clientId;
  }

  /// The copy on this phone, if there is one - a stat call, no waiting.
  static File? fileForSync({String? messageId, String? clientId}) {
    final root = _rootPath;
    if (root == null) return null;
    try {
      for (final key in _keys(messageId, clientId)) {
        final dir = Directory('$root/${_safe(key)}');
        if (!dir.existsSync()) continue;
        for (final e in dir.listSync()) {
          if (e is File) return e;
        }
      }
    } catch (_) {}
    return null;
  }

  /// Keeps [bytes] as the document of the message [messageId] (or
  /// [clientId] while it has no server id).
  static Future<File?> keepBytes(Uint8List bytes,
      {String? messageId, String? clientId, required String fileName}) async {
    final key = _keys(messageId, clientId).firstOrNull;
    if (key == null) return null;
    try {
      final dir = Directory('${(await _root()).path}/${_safe(key)}');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final file = File('${dir.path}/${safeFileName(fileName)}');
      await file.writeAsBytes(bytes, flush: true);
      return file;
    } catch (_) {
      return null;
    }
  }

  /// Moves what was kept under [clientId] to the settled [messageId], once
  /// the server has the document.
  static Future<void> settle({required String clientId, required String messageId}) async {
    if (clientId.isEmpty || messageId.isEmpty || clientId == messageId) return;
    try {
      final root = (await _root()).path;
      final from = Directory('$root/${_safe(clientId)}');
      final to = Directory('$root/${_safe(messageId)}');
      if (!from.existsSync() || to.existsSync()) return;
      await from.rename(to.path);
    } catch (_) {}
  }

  static Future<void> remove({String? messageId, String? clientId}) async {
    try {
      final root = (await _root()).path;
      for (final key in _keys(messageId, clientId)) {
        final dir = Directory('$root/${_safe(key)}');
        if (dir.existsSync()) await dir.delete(recursive: true);
      }
    } catch (_) {}
  }
}
