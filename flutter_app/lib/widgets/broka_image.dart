// One widget for every image the backend sends, whatever shape it is in.
//
// Images now arrive as URLs of stored WebP files: absolute ones from
// Cloudflare R2, or paths like "/media/i/..." when the backend stores them
// itself. Listings and stores that haven't been converted yet still send
// base64 - a data URI, or bare base64 for listing photos. This renders all
// of them, caches network images on disk, and falls back to [placeholder]
// for anything missing or unreadable instead of throwing.
//
// A photo comes in three sizes and each one is its own file. A card asks for
// the small one, so one missing file used to mean an emoji where a photo
// should be, even with the same picture sitting there in another size.
// [BrokaImage.fallbacks] lists those other sizes: they are tried in order,
// each URL at most once, and only when everything fails does [placeholder]
// appear.
import 'dart:convert';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart'
    show debugPrint, kDebugMode, visibleForTesting;
import 'package:flutter/material.dart';

import '../main.dart';
import '../services/api_service.dart';

/// Builds the widget that downloads one image. [BrokaImage.networkImageBuilder]
/// holds the real one (a CachedNetworkImage); tests swap it, because that
/// needs network, a disk cache and plugins to run.
typedef NetworkImageBuilder = Widget Function({
  required String url,
  required BoxFit fit,
  double? width,
  double? height,
  required Widget Function(BuildContext, String) placeholder,
  required Widget Function(BuildContext, String, Object) errorWidget,
});

class BrokaImage extends StatelessWidget {
  const BrokaImage(
    this.source, {
    super.key,
    this.fallbacks = const [],
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.placeholder,
  });

  final String? source;

  /// Other sizes of the same picture, tried in order when [source] can't be
  /// loaded. Pass only sizes the API actually sent. A URL that repeats an
  /// earlier one (the backend repeats a URL for a size an image lacks) is
  /// skipped, so nothing is requested twice.
  final List<String?> fallbacks;
  final BoxFit fit;
  final double? width;
  final double? height;
  final Widget? placeholder;

  static final RegExp _absoluteUrl = RegExp(r'^https?://', caseSensitive: false);

  /// A URL a network image can load, or null if [source] isn't one.
  ///
  /// The only relative paths the backend sends are its own image routes,
  /// "/media/...". Any leading slash used to count as one, but bare base64
  /// of a JPEG starts "/9j/" - so every selfie was fetched from the API as
  /// a path, failed, and showed an initial where the photo should be.
  static String? networkUrl(String? source) =>
      resolveNetworkUrl(source, ApiService.baseUrl);

  /// [networkUrl] against an explicit API base. Absolute URLs are returned
  /// exactly as given - re-encoding one would break a signed URL. A base
  /// written with a trailing slash doesn't double it ("//media/..." is a
  /// different path to the server). Anything without a host - "https://" on
  /// its own, a relative path with no base - isn't loadable, so it's null.
  @visibleForTesting
  static String? resolveNetworkUrl(String? source, String apiBase) {
    final s = source?.trim();
    if (s == null || s.isEmpty) return null;
    final String url;
    if (_absoluteUrl.hasMatch(s)) {
      url = s;
    } else if (s.startsWith('/media/')) {
      url = '${apiBase.replaceFirst(RegExp(r'/+$'), '')}$s';
    } else {
      return null;
    }
    final uri = Uri.tryParse(url);
    return uri != null && uri.hasAuthority && uri.host.isNotEmpty ? url : null;
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

  // ── Files the server has said it doesn't have ──────────────────────────────
  //
  // Flutter doesn't keep a failed download, so a card scrolled back into view
  // - or the same photo on the next screen - asked the server for the same
  // missing file again, every time. A 404/410 is remembered for a while and
  // that URL is skipped. Only those two: a timeout or a dropped connection
  // says nothing about the file, and remembering it would leave photos blank
  // for the whole window after the network came back.
  static const Duration _missingFor = Duration(minutes: 10);
  static const int _missingCap = 200;
  static final Map<String, DateTime> _missingSince = <String, DateTime>{};
  static final Set<String> _reported = <String>{};

  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  @visibleForTesting
  static void resetFailureMemory() {
    _missingSince.clear();
    _reported.clear();
  }

  static bool _knownMissing(String url) {
    final since = _missingSince[url];
    if (since == null) return false;
    if (clock().difference(since) < _missingFor) return true;
    _missingSince.remove(url);
    return false;
  }

  static void _loadFailed(String url, Object error) {
    final status = _httpStatus(error);
    if (status == 404 || status == 410) {
      _missingSince.remove(url); // re-add at the end: oldest entry goes first
      _missingSince[url] = clock();
      while (_missingSince.length > _missingCap) {
        _missingSince.remove(_missingSince.keys.first);
      }
    }
    // Once per URL, debug builds only. Scheme, host and path - never the
    // query string, where a signed URL keeps its signature - and the error's
    // class, never its text, which can repeat the full URL.
    if (kDebugMode && _reported.add(url)) {
      debugPrint('[BrokaImage] could not load ${redactUrl(url)} '
          '(${error.runtimeType}${status != null ? ', HTTP $status' : ''})');
    }
  }

  /// The HTTP status an image download failed with, or null. The cache
  /// manager's exception carries it as `statusCode`; its message names it too.
  static int? _httpStatus(Object error) {
    try {
      final status = (error as dynamic).statusCode;
      if (status is int) return status;
    } catch (_) {
      // not an exception that carries one
    }
    final match =
        RegExp(r'statusCode:\s*(\d{3})').firstMatch(error.toString());
    return match == null ? null : int.tryParse(match.group(1)!);
  }

  /// [url] as it may appear in a log: no user info, query or fragment.
  @visibleForTesting
  static String redactUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasAuthority) return '<not a url>';
    return '${uri.scheme}://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}'
        '${uri.path}';
  }

  /// What downloads one image. Tests replace it; see [NetworkImageBuilder].
  @visibleForTesting
  static NetworkImageBuilder networkImageBuilder = _cachedNetworkImage;

  static Widget _cachedNetworkImage({
    required String url,
    required BoxFit fit,
    double? width,
    double? height,
    required Widget Function(BuildContext, String) placeholder,
    required Widget Function(BuildContext, String, Object) errorWidget,
  }) =>
      CachedNetworkImage(
        imageUrl: url,
        fit: fit,
        width: width,
        height: height,
        fadeInDuration: const Duration(milliseconds: 150),
        placeholder: placeholder,
        errorWidget: errorWidget,
      );

  /// Drawn while a network image downloads, and when the source is missing
  /// or unreadable. Callers that supply a placeholder (an emoji, BROKA's
  /// mark, a silhouette) get it in both cases.
  ///
  /// The loading case used to be a flat bgMid rectangle regardless of what
  /// the caller passed, so every card painted a dark blank - the same look
  /// as "this listing has no photo" - for as long as the fetch took, and
  /// forever if it never completed. A slow or stuck image now reads as
  /// loading rather than as missing.
  Widget _fallback() =>
      placeholder ??
      Container(width: width, height: height, color: BrokaColors.bgMid);

  @override
  Widget build(BuildContext context) {
    final candidates = <_Candidate>[];
    final seen = <String>{};
    for (final raw in [source, ...fallbacks]) {
      final s = raw?.trim();
      if (s == null || s.isEmpty) continue;
      final url = networkUrl(s);
      if (seen.add(url ?? s)) candidates.add(_Candidate(s, url));
    }
    return _from(candidates, 0);
  }

  /// The first of [candidates] from [start] that can be tried, or the
  /// placeholder. A candidate that fails builds the next one in its place,
  /// so each is requested once per widget.
  Widget _from(List<_Candidate> candidates, int start) {
    for (var i = start; i < candidates.length; i++) {
      final url = candidates[i].url;
      if (url != null) {
        if (_knownMissing(url)) continue;
        return networkImageBuilder(
          url: url,
          fit: fit,
          width: width,
          height: height,
          placeholder: (_, __) => _fallback(),
          errorWidget: (_, failedUrl, error) {
            _loadFailed(failedUrl, error);
            return _from(candidates, i + 1);
          },
        );
      }
      final bytes = inlineBytes(candidates[i].raw);
      if (bytes != null) {
        return Image.memory(
          bytes,
          fit: fit,
          width: width,
          height: height,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => _from(candidates, i + 1),
        );
      }
    }
    return _fallback();
  }
}

class _Candidate {
  const _Candidate(this.raw, this.url);

  /// The source as sent, trimmed.
  final String raw;

  /// Its network URL, or null for inline base64 (or something unusable).
  final String? url;
}
