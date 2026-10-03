// One widget for every image the backend sends, whatever shape it is in.
//
// Images now arrive as URLs of stored WebP files: absolute ones from
// Cloudflare R2, or paths like "/media/i/..." when the backend stores them
// itself. Listings and stores that haven't been converted yet still send
// base64 - a data URI, or bare base64 for listing photos. This renders all
// of them, caches network images on disk, and falls back to [placeholder]
// for anything missing or unreadable instead of throwing.
import 'dart:convert';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../main.dart';
import '../services/api_service.dart';

class BrokaImage extends StatelessWidget {
  const BrokaImage(
    this.source, {
    super.key,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.placeholder,
  });

  final String? source;
  final BoxFit fit;
  final double? width;
  final double? height;
  final Widget? placeholder;

  /// A URL a network image can load, or null if [source] isn't one.
  ///
  /// The only relative paths the backend sends are its own image routes,
  /// "/media/...". Any leading slash used to count as one, but bare base64
  /// of a JPEG starts "/9j/" - so every selfie was fetched from the API as
  /// a path, failed, and showed an initial where the photo should be.
  static String? networkUrl(String? source) {
    final s = source?.trim();
    if (s == null || s.isEmpty) return null;
    if (s.startsWith('http://') || s.startsWith('https://')) return s;
    if (s.startsWith('/media/')) return '${ApiService.baseUrl}$s';
    return null;
  }

  /// Bytes for a data URI or bare base64 string, or null.
  static Uint8List? inlineBytes(String? source) {
    final s = source?.trim();
    if (s == null || s.isEmpty || networkUrl(s) != null) return null;
    final payload = s.startsWith('data:') ? s.substring(s.indexOf(',') + 1) : s;
    try {
      return base64Decode(payload);
    } catch (_) {
      return null;
    }
  }

  /// An ImageProvider for circle avatars and decorations, or null.
  static ImageProvider? provider(String? source) {
    final url = networkUrl(source);
    if (url != null) return CachedNetworkImageProvider(url);
    final bytes = inlineBytes(source);
    return bytes != null ? MemoryImage(bytes) : null;
  }

  Widget _fallback() =>
      placeholder ??
      Container(width: width, height: height, color: BrokaColors.bgMid);

  @override
  Widget build(BuildContext context) {
    final url = networkUrl(source);
    if (url != null) {
      return CachedNetworkImage(
        imageUrl: url,
        fit: fit,
        width: width,
        height: height,
        fadeInDuration: const Duration(milliseconds: 150),
        placeholder: (_, __) =>
            Container(width: width, height: height, color: BrokaColors.bgMid),
        errorWidget: (_, __, ___) => _fallback(),
      );
    }
    final bytes = inlineBytes(source);
    if (bytes != null) {
      return Image.memory(
        bytes,
        fit: fit,
        width: width,
        height: height,
        gaplessPlayback: true,
        errorBuilder: (_, __, ___) => _fallback(),
      );
    }
    return _fallback();
  }
}
