// Photos are made no bigger than the server keeps before they are uploaded.
//
// The server re-encodes every upload and keeps at most 1600 px on the long
// side (backend/api/core/image_processing.py). BROKA's camera takes 1080p
// JPEGs at the camera's own quality - often 1-2 MB a shot - and a gallery
// pick can be larger still; the difference was mobile data spent sending
// detail the server then threw away. A large JPEG is re-encoded here first:
// at most [maxSide] px, quality [quality], turned upright from its EXIF
// orientation (the re-encode drops the tag that said which way was up).
//
// Only JPEGs: a PNG or WebP may be a store logo with transparency, which a
// JPEG would flatten. Small files are sent as they are - re-encoding them
// saves little and costs the phone time. If decoding fails, or the result
// is not smaller, the original goes up unchanged.
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:image/image.dart' as img;

class UploadShrink {
  UploadShrink._();

  static const int maxSide = 1600;
  static const int quality = 82;

  /// Files at or below this are sent untouched.
  static const int threshold = 400 * 1024;

  static bool isJpeg(List<int> bytes) =>
      bytes.length > 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF;

  /// [bytes], or a smaller JPEG of the same picture.
  static Future<List<int>> forUpload(List<int> bytes) async {
    if (bytes.length <= threshold || !isJpeg(bytes)) return bytes;
    try {
      final input = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
      // Off the UI thread: decoding a 1080p JPEG in Dart takes long enough
      // to drop frames on the phones most sellers carry.
      final out = await Isolate.run(() => shrinkJpeg(input));
      if (out != null && out.length < bytes.length) return out;
    } catch (e) {
      debugPrint('[UploadShrink] kept the original: ${e.runtimeType}');
    }
    return bytes;
  }

  /// The re-encode itself, synchronous. Null if [bytes] can't be decoded.
  @visibleForTesting
  static Uint8List? shrinkJpeg(Uint8List bytes, {int side = maxSide, int jpegQuality = quality}) {
    final decoded = img.decodeJpg(bytes);
    if (decoded == null) return null;
    var picture = img.bakeOrientation(decoded);
    final longest = picture.width > picture.height ? picture.width : picture.height;
    if (longest > side) {
      picture = picture.width >= picture.height
          ? img.copyResize(picture, width: side, interpolation: img.Interpolation.average)
          : img.copyResize(picture, height: side, interpolation: img.Interpolation.average);
    }
    return img.encodeJpg(picture, quality: jpegQuality);
  }
}
