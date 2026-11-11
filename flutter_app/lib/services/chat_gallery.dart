// Saving a chat photo to the phone's gallery (2026-11-11): nothing could
// keep a photo someone sent - it lived only inside the chat.
//
// Android's own MediaStore through a small channel in MainActivity
// (ChatGallery.kt) rather than a plugin, as the documents, ringtone and
// share channels are: CI builds with a pinned Flutter and Android Gradle
// Plugin. Photos go to Pictures/BROKA, where the gallery app shows them. A
// photo the server re-encoded to WebP is saved as a JPEG, which every
// gallery and every app it may be shared to opens. Android 9 and older ask
// for the storage permission first; 10 and newer need none.
//
// Elsewhere (iOS, which BROKA does not ship yet) the share sheet opens with
// the photo, and its "Save Image" keeps it.
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart' show Share, XFile;

enum GallerySaveResult { saved, shared, permissionDenied, failed }

class ChatGallery {
  ChatGallery._();

  static const MethodChannel channel = MethodChannel('com.broka.app/gallery');

  /// Whether the Android channel is used - for tests, which run on
  /// neither platform.
  @visibleForTesting
  static bool? debugUseChannel;

  static bool get _useChannel => debugUseChannel ?? (!kIsWeb && Platform.isAndroid);

  /// Keep [bytes] (a photo) in the phone's gallery under [name] (no
  /// extension: the type is read from the bytes).
  static Future<GallerySaveResult> saveImage(Uint8List bytes, {required String name}) async {
    if (bytes.isEmpty) return GallerySaveResult.failed;
    if (_useChannel) {
      var answer = await _save(bytes, name);
      if (answer == 'permission') {
        // Android 9 and older: writing to Pictures takes the permission.
        final status = await Permission.storage.request();
        if (!status.isGranted) return GallerySaveResult.permissionDenied;
        answer = await _save(bytes, name);
      }
      return answer == 'saved' ? GallerySaveResult.saved : GallerySaveResult.failed;
    }
    try {
      await Share.shareXFiles([
        XFile.fromData(bytes, mimeType: mimeOf(bytes), name: '$name.${extensionOf(bytes)}'),
      ]);
      return GallerySaveResult.shared;
    } catch (e) {
      debugPrint('[ChatGallery] share failed: ${e.runtimeType}');
      return GallerySaveResult.failed;
    }
  }

  static Future<String?> _save(Uint8List bytes, String name) async {
    try {
      return await channel.invokeMethod<String>('saveImage', {'bytes': bytes, 'name': name});
    } catch (e) {
      // An old build's MainActivity has no such channel.
      debugPrint('[ChatGallery] save failed: ${e.runtimeType}');
      return 'failed';
    }
  }

  /// A photo the chat has only as a link.
  static Future<Uint8List?> download(String url) async {
    try {
      final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
      return res.statusCode == 200 ? res.bodyBytes : null;
    } catch (_) {
      return null;
    }
  }

  static bool _startsWith(Uint8List b, List<int> sig, [int at = 0]) {
    if (b.length < at + sig.length) return false;
    for (var i = 0; i < sig.length; i++) {
      if (b[at + i] != sig[i]) return false;
    }
    return true;
  }

  static String mimeOf(Uint8List b) {
    if (_startsWith(b, const [0x89, 0x50, 0x4E, 0x47])) return 'image/png';
    if (_startsWith(b, const [0x52, 0x49, 0x46, 0x46]) &&
        _startsWith(b, const [0x57, 0x45, 0x42, 0x50], 8)) {
      return 'image/webp';
    }
    return 'image/jpeg';
  }

  static String extensionOf(Uint8List b) => switch (mimeOf(b)) {
        'image/png' => 'png',
        'image/webp' => 'webp',
        _ => 'jpg',
      };

  /// What the user is told.
  static String describe(GallerySaveResult result) => switch (result) {
        GallerySaveResult.saved => "Saved to your phone's gallery",
        GallerySaveResult.shared => 'Choose where to keep the photo',
        GallerySaveResult.permissionDenied =>
          'BROKA needs permission to save photos. Allow it in Settings.',
        GallerySaveResult.failed => "Couldn't save the photo. Try again.",
      };
}
