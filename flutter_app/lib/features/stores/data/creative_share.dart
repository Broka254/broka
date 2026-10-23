// Taking a Marketing Studio creative off the phone.
//
// BROKA does not post to social networks - there is no publishing
// permission, and pretending otherwise is exactly what the studio refuses
// to do. So the end of the workflow is the phone's own share sheet: the
// seller saves the poster to their gallery, or sends it to WhatsApp,
// Instagram, or anywhere else they already post.
//
// This is an injectable wrapper for the same reason StoreShareCard injects
// StoreShare: the screen is tested without a platform plugin, and a device
// where the share sheet cannot open gets an honest failure instead of a
// spinner that never ends.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';

abstract class CreativeShare {
  /// Saves or sends the rendered poster at [url], with [caption] attached
  /// so the seller does not have to retype it. Returns false when the image
  /// could not be fetched or no share sheet opened.
  Future<bool> image(
    String url, {
    required String caption,
    String? fileName,
    Rect? origin,
  });

  /// Saves or sends text only: a caption with its tracked store link.
  Future<bool> text(String text, {Rect? origin});
}

class DeviceCreativeShare implements CreativeShare {
  const DeviceCreativeShare();

  @override
  Future<bool> image(
    String url, {
    required String caption,
    String? fileName,
    Rect? origin,
  }) async {
    try {
      // The poster is the server's own render, fetched as bytes so the
      // sheet shares a real file rather than a link to a private draft.
      final response = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) return false;
      final result = await Share.shareXFiles(
        [
          XFile.fromData(
            response.bodyBytes,
            mimeType: 'image/png',
            name: fileName ?? 'broka-creative.png',
          ),
        ],
        text: caption,
        sharePositionOrigin: origin,
      );
      return result.status != ShareResultStatus.unavailable;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> text(String text, {Rect? origin}) async {
    try {
      final result = await Share.share(text, sharePositionOrigin: origin);
      return result.status != ShareResultStatus.unavailable;
    } catch (_) {
      return false;
    }
  }
}
