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

/// What the share sheet reported. A dismissed sheet is not a share, and
/// `unconfirmed` means the platform could not say - neither may be counted
/// as something BROKA observed.
enum CreativeShareOutcome {
  shared,
  dismissed,
  unconfirmed,
  failed,
}

abstract class CreativeShare {
  /// Saves or sends the rendered poster at [url], with [caption] attached
  /// so the seller does not have to retype it. [failed] when the image
  /// could not be fetched or no share sheet opened.
  Future<CreativeShareOutcome> image(
    String url, {
    required String caption,
    String? fileName,
    Rect? origin,
  });

  /// Saves or sends text only: a caption with its tracked store link.
  Future<CreativeShareOutcome> text(String text, {Rect? origin});
}

CreativeShareOutcome _outcomeOf(ShareResult result) => switch (result.status) {
      ShareResultStatus.success => CreativeShareOutcome.shared,
      ShareResultStatus.dismissed => CreativeShareOutcome.dismissed,
      ShareResultStatus.unavailable => CreativeShareOutcome.unconfirmed,
    };

class DeviceCreativeShare implements CreativeShare {
  const DeviceCreativeShare();

  @override
  Future<CreativeShareOutcome> image(
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
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        return CreativeShareOutcome.failed;
      }
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
      return _outcomeOf(result);
    } catch (_) {
      return CreativeShareOutcome.failed;
    }
  }

  @override
  Future<CreativeShareOutcome> text(String text, {Rect? origin}) async {
    try {
      final result = await Share.share(text, sharePositionOrigin: origin);
      return _outcomeOf(result);
    } catch (_) {
      return CreativeShareOutcome.failed;
    }
  }
}
